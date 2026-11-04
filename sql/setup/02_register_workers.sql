-- Выполняется только на координаторе после запуска worker-1 и worker-2.
-- Имя coordinator разрешается внутренней сетью Docker Compose.
SELECT citus_set_coordinator_host('coordinator', 5432);

-- Повторный запуск не добавляет уже зарегистрированные узлы.
SELECT citus_add_node('worker-1', 5432)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_dist_node
    WHERE nodename = 'worker-1'
      AND nodeport = 5432
      AND noderole = 'primary'
);

SELECT citus_add_node('worker-2', 5432)
WHERE NOT EXISTS (
    SELECT 1
    FROM pg_dist_node
    WHERE nodename = 'worker-2'
      AND nodeport = 5432
      AND noderole = 'primary'
);

-- Проверка зарегистрированных рабочих узлов и соединений между узлами.
SELECT *
FROM citus_get_active_worker_nodes()
ORDER BY node_name, node_port;

SELECT *
FROM citus_check_cluster_node_health()
ORDER BY from_nodename, from_nodeport, to_nodename, to_nodeport;
