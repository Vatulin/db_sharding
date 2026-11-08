"""Проверки управления воркерами без запущенного кластера."""

import unittest
from unittest.mock import MagicMock, patch

from web import db, services
from web.app import create_app


class ClusterTests(unittest.TestCase):
    def run_action(self, action, responses, name=None, node_id=None):
        connection = MagicMock()
        cursor = connection.cursor.return_value.__enter__.return_value
        cursor.fetchone.side_effect = responses
        with patch.object(services, 'get_connection') as connect:
            connect.return_value.__enter__.return_value = connection
            result = services.run_cluster_action(action, name, node_id)
        return result, cursor

    def test_add_arbitrary_worker(self):
        message, cursor = self.run_action('add', [{'acquired': True}, None, None], 'worker-27')
        cursor.execute.assert_any_call('SELECT citus_add_node(%s, %s)', ('worker-27', 5432))
        self.assertIn('worker-27 зарегистрирован', message)
        self.assertEqual(cursor.execute.call_args.args, ('SELECT pg_advisory_unlock(824731, 8)',))

    def test_invalid_names_never_connect(self):
        with patch.object(services, 'get_connection') as connect:
            for name in (None, '', '-worker', 'worker-', 'a' * 64, 'worker; DROP TABLE users', 'coordinator', 'baseline'):
                with self.subTest(name=name), self.assertRaises(services.ValidationError):
                    services.run_cluster_action('add', name)
            connect.assert_not_called()

    def test_duplicate_busy_and_locked_cluster(self):
        for responses in ([{'acquired': False}], [{'acquired': True}, {'state': 'running'}],
                          [{'acquired': True}, None, {'nodeid': 5}]):
            with self.subTest(responses=responses), self.assertRaises(services.ValidationError):
                self.run_action('add', responses, 'worker-27')

    def test_existing_rebalance(self):
        _, cursor = self.run_action('rebalance', [{'acquired': True}])
        self.assertTrue(any('citus_rebalance_start' in call.args[0] for call in cursor.execute.call_args_list))

    def test_form_passes_name_and_checks_csrf(self):
        app = create_app()
        app.config['TESTING'] = True
        client = app.test_client()
        with patch('web.app.run_cluster_action', return_value='Добавлен') as action:
            self.assertEqual(client.post('/cluster/add', data={'worker_name': 'worker-27'}).status_code, 400)
            action.assert_not_called()
            with client.session_transaction() as session:
                session['cluster_token'] = 'token'
            response = client.post('/cluster/add', data={'worker_name': 'worker-27', 'csrf_token': 'token'})
            self.assertEqual(response.status_code, 303)
            action.assert_called_once_with('add', 'worker-27', None)

    def test_drain_and_remove_use_registered_address(self):
        node = dict(nodeid=27, groupid=12, nodename='db.example', nodeport=5544,
                    noderole='primary', isactive=True, shouldhaveshards=False)
        for action, final_response, sql in (
            ('drain', {'exists': 1}, 'SELECT citus_drain_node(%s, %s)'),
            ('remove', None, 'SELECT citus_remove_node(%s, %s)'),
        ):
            with self.subTest(action=action):
                responses = [{'acquired': True}, None, node, final_response]
                if action == 'remove':
                    responses.append(None)
                message, cursor = self.run_action(action, responses, node_id='27')
                cursor.execute.assert_any_call(sql, ('db.example', 5544))
                self.assertIn('db.example:5544', message)
                if action == 'remove':
                    queries = [call.args[0] for call in cursor.execute.call_args_list]
                    self.assertLess(queries.index('CALL citus_cleanup_orphaned_resources()'), queries.index(sql))

    def test_unsafe_operations_do_not_change_cluster(self):
        node = dict(nodeid=27, groupid=12, nodename='worker-27', nodeport=5432,
                    noderole='primary', isactive=True, shouldhaveshards=False)
        cases = [
            ('drain', [None]),
            ('remove', [dict(node, groupid=0)]),
            ('drain', [dict(node, noderole='secondary')]),
            ('drain', [dict(node, isactive=False)]),
            ('drain', [node, None]),
            ('remove', [dict(node, shouldhaveshards=True)]),
            ('remove', [node, {'exists': 1}]),
            ('remove', [node, None, {'exists': 1}]),
        ]
        for action, responses in cases:
            with self.subTest(action=action, responses=responses):
                with patch.object(services, 'get_connection') as connect:
                    cursor = connect.return_value.__enter__.return_value.cursor.return_value.__enter__.return_value
                    cursor.fetchone.side_effect = [{'acquired': True}, None, *responses]
                    with self.assertRaises(services.ValidationError):
                        services.run_cluster_action(action, node_id='27')
                    queries = [call.args[0] for call in cursor.execute.call_args_list]
                    self.assertFalse(any('citus_drain_node' in query or 'citus_remove_node' in query for query in queries))
                    self.assertEqual(queries[-1], 'SELECT pg_advisory_unlock(824731, 8)')

    def test_node_actions_require_id_and_idle_cluster(self):
        for action in ('drain', 'remove'):
            for node_id in (None, '', '0', '-1', 'bad'):
                with self.subTest(action=action, node_id=node_id), patch.object(services, 'get_connection') as connect:
                    with self.assertRaises(services.ValidationError):
                        services.run_cluster_action(action, node_id=node_id)
                    connect.assert_not_called()
            with self.assertRaises(services.ValidationError):
                self.run_action(action, [{'acquired': True}, {'state': 'running'}], node_id='27')

    def test_validation_errors_survive_database_context(self):
        with patch.object(db.psycopg, 'connect'):
            with self.assertRaises(services.ValidationError):
                with db.get_connection():
                    raise services.ValidationError('Сначала освободите выбранный воркер.')

    def test_node_forms_and_routes(self):
        app = create_app()
        app.config['TESTING'] = True
        client = app.test_client()
        nodes = [dict(nodeid=i, groupid=i, nodename=f'worker-{i}', nodeport=5432,
                      noderole='primary', isactive=True, shouldhaveshards=False) for i in (0, 27, 41)]
        cluster = dict(nodes=nodes, shards=[], shard_total=0, shards_limited=False, jobs=[], busy=False)
        with patch('web.app.get_cluster_data', return_value=cluster):
            response = client.get('/cluster')
            self.assertEqual(response.status_code, 200)
            html = response.get_data(as_text=True)
            self.assertNotIn('worker-3', html)
            self.assertNotIn('drain_worker.sql', html)
            self.assertNotIn('name="node_id" value="0"', html)
            for node_id in ('27', '41'):
                self.assertEqual(html.count(f'name="node_id" value="{node_id}"'), 2)
        for operation in ('drain', 'remove'):
            with patch('web.app.run_cluster_action', return_value='Готово') as action:
                with client.session_transaction() as session:
                    token = session['cluster_token']
                self.assertEqual(client.post(f'/cluster/{operation}', data={'node_id': '41'}).status_code, 400)
                action.assert_not_called()
                response = client.post(f'/cluster/{operation}', data={'node_id': '41', 'csrf_token': token})
                self.assertEqual(response.status_code, 303)
                action.assert_called_once_with(operation, None, '41')


if __name__ == '__main__':
    unittest.main()
