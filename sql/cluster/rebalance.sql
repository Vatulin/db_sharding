-- На координаторе, через psql с ON_ERROR_STOP=1, без --single-transaction.
-- Фоновая операция: успешный запуск ещё не означает завершение переноса.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM citus_rebalance_status()
               WHERE state::text NOT IN ('finished', 'failed', 'cancelled')) THEN
        RAISE EXCEPTION 'Балансировка уже выполняется.';
    END IF;
    IF (SELECT count(*) FROM pg_dist_node
        WHERE groupid > 0 AND noderole = 'primary' AND isactive AND shouldhaveshards) < 2 THEN
        RAISE EXCEPTION 'Для балансировки нужны хотя бы два активных рабочих узла.';
    END IF;
END $$;
-- step
SELECT citus_rebalance_start(rebalance_strategy => 'by_shard_count');
