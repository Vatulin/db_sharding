-- На координаторе. Сначала в Ubuntu: docker compose --profile scale up -d --wait worker-3
-- Запускать psql с ON_ERROR_STOP=1. Регистрация проверяет подключение к узлу.
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM citus_rebalance_status()
               WHERE state::text NOT IN ('finished', 'failed', 'cancelled')) THEN
        RAISE EXCEPTION 'Дождитесь завершения текущей балансировки.';
    END IF;
    IF EXISTS (SELECT 1 FROM pg_dist_node WHERE nodename = 'worker-3' AND nodeport = 5432) THEN
        RAISE EXCEPTION 'worker-3 уже зарегистрирован.';
    END IF;
END $$;
-- step
SELECT citus_add_node('worker-3', 5432);
