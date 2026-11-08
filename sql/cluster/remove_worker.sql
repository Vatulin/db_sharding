-- На координаторе после успешного drain_worker.sql, с ON_ERROR_STOP=1.
-- Проверка и удаление в одном SQL-блоке. citus_remove_node дополнительно
-- проверяет размещения; оставшиеся копии эталонных таблиц удаляет сам Citus.
DO $$
DECLARE
    target_group integer;
    accepts_shards boolean;
BEGIN
    IF EXISTS (SELECT 1 FROM citus_rebalance_status()
               WHERE state::text NOT IN ('finished', 'failed', 'cancelled')) THEN
        RAISE EXCEPTION 'Дождитесь завершения текущей балансировки.';
    END IF;
    SELECT groupid, shouldhaveshards INTO target_group, accepts_shards
    FROM pg_dist_node
    WHERE nodename = 'worker-3' AND nodeport = 5432 AND noderole = 'primary';
    IF target_group IS NULL OR target_group = 0 THEN
        RAISE EXCEPTION 'Рабочий узел worker-3 не найден.';
    END IF;
    IF accepts_shards THEN
        RAISE EXCEPTION 'Сначала выполните drain_worker.sql для worker-3.';
    END IF;
    IF EXISTS (
        SELECT 1 FROM pg_dist_placement p
        JOIN pg_dist_shard s USING (shardid)
        JOIN pg_dist_partition d ON d.logicalrelid = s.logicalrelid
        WHERE p.groupid = target_group AND d.partmethod <> 'n'
    ) THEN
        RAISE EXCEPTION 'На worker-3 ещё есть распределённые шарды.';
    END IF;
    PERFORM citus_remove_node('worker-3', 5432);
END $$;
