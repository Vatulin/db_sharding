-- Только чтение, запуск на координаторе Citus.
-- Одна строка на размещение; узлы без шардов тоже включены.
-- isactive отражает метаданные, а не текущую сетевую доступность.
-- Размеры запрашиваются через citus_shards: недоступный воркер может вызвать ошибку.
SELECT n.nodeid, n.groupid, n.nodename, n.nodeport, n.noderole,
       n.isactive, n.shouldhaveshards,
       count(s.shardid) OVER (PARTITION BY n.nodeid) AS placements_on_node,
       s.table_name, s.shardid, s.shard_name, s.citus_table_type,
       s.shard_size AS shard_bytes,
       pg_size_pretty(s.shard_size) AS shard_size
FROM pg_dist_node n
LEFT JOIN citus_shards s
  ON s.nodename = n.nodename AND s.nodeport = n.nodeport
ORDER BY n.nodeid, s.table_name, s.shardid;
