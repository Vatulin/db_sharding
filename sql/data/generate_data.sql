-- Запуск через psql на координаторе или в baseline после sql/setup.
-- Параметры: -v users_count=10000 -v orders_count=100000 -v events_count=200000.
\set ON_ERROR_STOP on
\if :{?users_count}
\else
  \set users_count 10000
\endif
\if :{?orders_count}
\else
  \set orders_count 100000
\endif
\if :{?events_count}
\else
  \set events_count 200000
\endif

BEGIN;
-- Проверка параметров до записи в предметные таблицы.
CREATE TEMP TABLE generation_parameters (
    users_count bigint CHECK (users_count > 0),
    orders_count bigint CHECK (orders_count >= 0),
    events_count bigint CHECK (events_count >= 0)
) ON COMMIT DROP;
INSERT INTO generation_parameters VALUES
    (:'users_count'::bigint, :'orders_count'::bigint, :'events_count'::bigint);

DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM public.users)
       OR EXISTS (SELECT 1 FROM public.orders)
       OR EXISTS (SELECT 1 FROM public.events) THEN
        RAISE EXCEPTION 'Загрузка отменена: users, orders и events должны быть пустыми.';
    END IF;
    IF (SELECT count(*) FROM public.order_statuses WHERE status_id BETWEEN 1 AND 4) <> 4
       OR (SELECT count(*) FROM public.event_types WHERE event_type_id BETWEEN 1 AND 4) <> 4 THEN
        RAISE EXCEPTION 'Сначала выполните sql/setup/04_seed_reference_data.sql.';
    END IF;
END $$;

INSERT INTO public.users (user_id, name, email, created_at)
SELECT i, 'Пользователь ' || i, 'user' || i || '@example.test',
       TIMESTAMPTZ '2025-01-01 00:00:00+00' + (i % 30) * INTERVAL '1 day'
FROM generate_series(1::bigint, :'users_count'::bigint) AS g(i);

INSERT INTO public.orders (user_id, order_id, status_id, total_amount, created_at)
SELECT 1 + (i - 1) % :'users_count'::bigint, i,
       (1 + (i - 1) % 4)::smallint,
       (100 + (i * 7919 % 990001))::numeric / 100,
       TIMESTAMPTZ '2025-02-01 00:00:00+00' + (i % 31536000) * INTERVAL '1 second'
FROM generate_series(1::bigint, :'orders_count'::bigint) AS g(i);

INSERT INTO public.events (user_id, event_id, event_type_id, created_at, payload)
SELECT 1 + (i - 1) % :'users_count'::bigint, i,
       (1 + (i - 1) % 4)::smallint,
       TIMESTAMPTZ '2025-02-01 00:00:00+00' + (i % 31536000) * INTERVAL '1 second',
       jsonb_build_object('source', 'generate_data', 'sequence', i)
FROM generate_series(1::bigint, :'events_count'::bigint) AS g(i);

-- Не понижаем текущие последовательности, даже если ранее были удалённые строки.
-- setval не откатывается при ROLLBACK; пропуски ID допустимы.
SELECT setval(pg_get_serial_sequence('public.users', 'user_id'),
              greatest(:'users_count'::bigint,
                       nextval(pg_get_serial_sequence('public.users', 'user_id'))), true);
SELECT setval(pg_get_serial_sequence('public.orders', 'order_id'),
              greatest(:'orders_count'::bigint,
                       nextval(pg_get_serial_sequence('public.orders', 'order_id'))), true);
SELECT setval(pg_get_serial_sequence('public.events', 'event_id'),
              greatest(:'events_count'::bigint,
                       nextval(pg_get_serial_sequence('public.events', 'event_id'))), true);
COMMIT;

ANALYZE public.users;
ANALYZE public.orders;
ANALYZE public.events;
SELECT 'users' AS table_name, count(*) AS rows FROM public.users
UNION ALL SELECT 'orders', count(*) FROM public.orders
UNION ALL SELECT 'events', count(*) FROM public.events;
