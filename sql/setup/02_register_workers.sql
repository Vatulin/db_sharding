-- Адрес координатора, доступный другим контейнерам.
SELECT citus_set_coordinator_host('coordinator', 5432);

-- Начальные рабочие узлы.
SELECT citus_add_node('worker-1', 5432);
SELECT citus_add_node('worker-2', 5432);

-- Проверка зарегистрированных рабочих узлов.
SELECT *
FROM citus_get_active_worker_nodes()
ORDER BY node_name, node_port;