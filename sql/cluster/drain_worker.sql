-- На координаторе, только из psql с ON_ERROR_STOP=1.
-- Синхронно освобождает worker-3; контейнер должен оставаться запущенным.
-- При ошибке узел может уже иметь shouldhaveshards=false: устраните причину
-- и повторите этот файл. Данные и узел автоматически не удаляются.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM citus_rebalance_status()
               WHERE state::text NOT IN ('finished', 'failed', 'cancelled')) THEN
        RAISE EXCEPTION 'Дождитесь завершения текущей балансировки.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_dist_node
                   WHERE nodename = 'worker-3' AND nodeport = 5432
                     AND groupid > 0 AND noderole = 'primary' AND isactive) THEN
        RAISE EXCEPTION 'Активный рабочий узел worker-3 не найден.';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_dist_node
                   WHERE groupid > 0 AND noderole = 'primary' AND isactive
                     AND shouldhaveshards AND nodename <> 'worker-3') THEN
        RAISE EXCEPTION 'Нет рабочего узла для переноса данных.';
    END IF;
END $$;
-- step
SELECT citus_drain_node('worker-3', 5432);
-- step
SELECT n.nodename, n.shouldhaveshards,
       count(p.placementid) FILTER (WHERE d.partmethod <> 'n') AS remaining_distributed_placements
FROM pg_dist_node n
LEFT JOIN pg_dist_placement p USING (groupid)
LEFT JOIN pg_dist_shard s USING (shardid)
LEFT JOIN pg_dist_partition d ON d.logicalrelid = s.logicalrelid
WHERE n.nodename = 'worker-3' AND n.nodeport = 5432
GROUP BY n.nodename, n.shouldhaveshards;
