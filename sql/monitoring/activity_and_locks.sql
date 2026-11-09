-- Только чтение, запуск на координаторе Citus, не на baseline.
-- Активность по всему кластеру, включая внутренние запросы на воркерах.
-- global_pid связывает распределённый запрос с ожиданиями citus_lock_waits.
-- Для idle in transaction выводится время транзакции, не время последнего запроса.
-- Ограничение: первые 250 строк; блокировки и самые долгие операции идут первыми.
SELECT a.nodeid, a.global_pid, a.pid, a.is_worker_query,
       a.usename, a.application_name, a.state,
       CASE WHEN a.state = 'active' THEN clock_timestamp() - a.query_start END AS query_duration,
       clock_timestamp() - a.xact_start AS transaction_duration,
       a.wait_event_type, a.wait_event,
       left(a.query, 1000) AS query,
       w.blocking_gpid, w.blocking_nodeid,
       left(w.current_statement_in_blocking_process, 1000) AS blocking_query
FROM citus_stat_activity a
LEFT JOIN citus_lock_waits w ON w.waiting_gpid = a.global_pid
WHERE a.datname = current_database()
  AND a.global_pid IS DISTINCT FROM citus_backend_gpid()
  AND (a.state IS DISTINCT FROM 'idle' OR w.waiting_gpid IS NOT NULL)
ORDER BY (w.waiting_gpid IS NOT NULL) DESC,
         coalesce(a.xact_start, a.query_start) ASC NULLS LAST,
         a.nodeid, a.pid
LIMIT 250;
