-- Разовое исправление по диагностике задания 8, операции 118.
-- Запускать на координаторе через psql, без --single-transaction.
-- Удаляет только три записи очереди очистки; таблицы и размещения не меняет.
\set ON_ERROR_STOP on

SELECT pg_advisory_lock(824731, 8);
SELECT citus_rebalance_stop();
SELECT citus_rebalance_wait();

BEGIN;
SET LOCAL lock_timeout = '5s';
LOCK TABLE pg_dist_cleanup IN SHARE ROW EXCLUSIVE MODE;

DO $$
DECLARE
    matching_records integer;
BEGIN
    IF EXISTS (SELECT 1 FROM citus_rebalance_status()
               WHERE state::text NOT IN ('finished', 'failed', 'cancelled')) THEN
        RAISE EXCEPTION 'Балансировка ещё не остановлена. Повторите после её остановки.';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_dist_node WHERE groupid = 8)
       OR EXISTS (SELECT 1 FROM pg_dist_placement WHERE groupid = 8) THEN
        RAISE EXCEPTION 'Группа 8 снова зарегистрирована или содержит размещения. Исправление отменено.';
    END IF;

    IF EXISTS (
        SELECT 1 FROM (VALUES (102012), (102044), (102076)) AS expected(shardid)
        WHERE NOT EXISTS (
            SELECT 1 FROM pg_dist_placement p
            JOIN pg_dist_node n USING (groupid)
            WHERE p.shardid = expected.shardid AND p.shardstate = 1
              AND n.groupid > 0 AND n.groupid <> 8
              AND n.noderole = 'primary' AND n.isactive
        )
    ) THEN
        RAISE EXCEPTION 'Не для всех трёх шардов найдено активное размещение. Исправление отменено.';
    END IF;

    SELECT count(*) INTO matching_records
    FROM pg_dist_cleanup
    WHERE operation_id = 118 AND node_group_id = 8
      AND object_type = 1 AND policy_type = 2
      AND (record_id, object_name) IN (
          (1118, 'public.users_102012'),
          (1119, 'public.orders_102044'),
          (1120, 'public.events_102076')
      );
    IF matching_records <> 3 THEN
        RAISE EXCEPTION 'Ожидались три записи очистки, найдено %. Состояние изменилось; исправление отменено.', matching_records;
    END IF;
END $$;

DELETE FROM pg_dist_cleanup
WHERE operation_id = 118 AND node_group_id = 8
  AND object_type = 1 AND policy_type = 2
  AND (record_id, object_name) IN (
      (1118, 'public.users_102012'),
      (1119, 'public.orders_102044'),
      (1120, 'public.events_102076')
  )
RETURNING *;
COMMIT;

SELECT pg_advisory_unlock(824731, 8);
\echo 'Три устаревшие записи удалены. Запустите балансировку на странице кластера.'
