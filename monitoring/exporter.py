"""Метрики каждого узла; список воркеров обновляется из pg_dist_node."""

import logging
import os
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from threading import Event, Lock
from time import monotonic

import psycopg
from psycopg.rows import dict_row
import yaml
from prometheus_client import CollectorRegistry, start_http_server
from prometheus_client.core import CounterMetricFamily, GaugeMetricFamily


CONFIG = yaml.safe_load(Path(__file__).with_name('exporter_queries.yaml').read_text(encoding='utf-8'))
LABELS = ['node', 'role', 'address']


def connect(host, port):
    return psycopg.connect(
        host=host, port=port, dbname=os.environ['POSTGRES_DB'],
        user=os.environ['POSTGRES_USER'], password=os.environ['POSTGRES_PASSWORD'],
        connect_timeout=3, autocommit=True, row_factory=dict_row,
        application_name='citus_monitoring',
        options='-c statement_timeout=3000 -c default_transaction_read_only=on',
    )


class ClusterCollector:
    def __init__(self):
        self.coordinator = ('coordinator', 'coordinator', os.getenv('COORDINATOR_HOST', 'coordinator'), 5432)
        self.baseline = ('baseline', 'baseline', 'baseline', 5432)
        self.workers = []
        self.lock = Lock()

    def describe(self):
        return []

    def discover(self):
        with connect(self.coordinator[2], self.coordinator[3]) as connection:
            rows = connection.execute('''
                SELECT nodename, nodeport FROM pg_dist_node
                WHERE groupid > 0 AND noderole = 'primary'
                ORDER BY nodeid
            ''').fetchall()
        # Не отбрасываем isactive=false: зарегистрированный узел тоже нужно проверять.
        return [(r['nodename'], 'worker', r['nodename'], r['nodeport']) for r in rows]

    def placements(self):
        with connect(self.coordinator[2], self.coordinator[3]) as connection:
            return connection.execute('''
                SELECT n.nodename, n.nodeport, count(p.placementid) AS placements
                FROM pg_dist_node n
                LEFT JOIN pg_dist_placement p ON p.groupid=n.groupid
                WHERE n.groupid > 0 AND n.noderole='primary'
                GROUP BY n.nodeid, n.nodename, n.nodeport
            ''').fetchall()

    @staticmethod
    def sample(node):
        started = monotonic()
        try:
            with connect(node[2], node[3]) as connection:
                values = connection.execute(CONFIG['query']).fetchone()
            if values is None:
                raise RuntimeError('Нет статистики базы')
            return node, values, monotonic() - started
        except (psycopg.Error, RuntimeError) as error:
            # Текст ошибки подключения может содержать параметры: не публикуем его.
            logging.warning('Не удалось опросить %s:%s (%s)', node[2], node[3], type(error).__name__)
            return node, None, monotonic() - started

    def collect(self):
        with self.lock:
            discovery_up = 1
            try:
                self.workers = self.discover()
            except psycopg.Error:
                discovery_up = 0
                logging.warning('Список узлов недоступен; используем последний известный список')
            nodes = [self.coordinator, self.baseline, *self.workers]
            with ThreadPoolExecutor(max_workers=16) as executor:
                samples = list(executor.map(self.sample, nodes))
            placement_rows = None
            try:
                placement_rows = self.placements()
            except psycopg.Error:
                logging.warning('Метаданные размещений недоступны')

        yield GaugeMetricFamily('citus_monitor_discovery_up', 'Обновление списка воркеров', value=discovery_up)
        yield GaugeMetricFamily('citus_monitor_metadata_up', 'Чтение размещений шардов', value=int(placement_rows is not None))
        up = GaugeMetricFamily('citus_node_up', 'Успешный сбор метрик с узла', labels=LABELS)
        duration = GaugeMetricFamily('citus_node_scrape_seconds', 'Длительность опроса узла', labels=LABELS)
        metrics = {}
        for key, spec in CONFIG['metrics'].items():
            family = CounterMetricFamily if spec['type'] == 'counter' else GaugeMetricFamily
            metrics[key] = family('citus_node_' + key, spec['help'], labels=LABELS)
        for node, values, seconds in samples:
            labels = [node[0], node[1], f'{node[2]}:{node[3]}']
            up.add_metric(labels, int(values is not None))
            duration.add_metric(labels, seconds)
            if values is not None:
                for key, metric in metrics.items():
                    metric.add_metric(labels, values[key])
        yield up
        yield duration
        yield from metrics.values()
        placements = GaugeMetricFamily('citus_node_shard_placements', 'Размещения шардов, включая справочники; по метаданным', labels=LABELS)
        for row in placement_rows or []:
            placements.add_metric([row['nodename'], 'worker', f"{row['nodename']}:{row['nodeport']}"], row['placements'])
        yield placements


if __name__ == '__main__':
    logging.basicConfig(level=logging.INFO)
    registry = CollectorRegistry()
    registry.register(ClusterCollector())
    start_http_server(9187, registry=registry)
    Event().wait()
