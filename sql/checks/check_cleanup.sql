-- Диагностика отложенной очистки. Только чтение; запуск на координаторе.
SELECT extversion FROM pg_extension WHERE extname = 'citus';

SELECT * FROM citus_rebalance_status();

SELECT c.*, n.nodeid, n.nodename, n.nodeport, n.isactive,
       (n.nodeid IS NULL) AS node_missing
FROM pg_dist_cleanup c
LEFT JOIN pg_dist_node n
  ON n.groupid = c.node_group_id AND n.noderole = 'primary'
ORDER BY c.record_id;

SELECT p.shardid, p.groupid, p.shardstate, n.nodeid, n.nodename, n.nodeport
FROM pg_dist_placement p
LEFT JOIN pg_dist_node n ON n.groupid = p.groupid AND n.noderole = 'primary'
WHERE p.shardid IN (102012, 102044, 102076)
ORDER BY p.shardid, p.groupid;
