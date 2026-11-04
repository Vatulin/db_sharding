-- Выполняется только на координаторе после 03_create_schema.sql
-- и 04_seed_reference_data.sql. Скрипт рассчитан на чистую схему, в которой таблицы ещё не распределены.

-- Справочники копируются на все рабочие узлы.
SELECT create_reference_table('public.order_statuses');
SELECT create_reference_table('public.event_types');

-- Пользователь — ключ распределения. Заказы и события размещаются
-- в той же группе, поэтому данные одного пользователя находятся на одном узле.
SELECT create_distributed_table('public.users', 'user_id');
SELECT create_distributed_table(
    'public.orders',
    'user_id',
    colocate_with => 'public.users'
);
SELECT create_distributed_table(
    'public.events',
    'user_id',
    colocate_with => 'public.users'
);

-- Внешние ключи допустимы: users, orders и events совместно размещены,
-- а справочники являются эталонными таблицами.
ALTER TABLE orders
    ADD CONSTRAINT orders_user_fk
        FOREIGN KEY (user_id)
        REFERENCES users (user_id);

ALTER TABLE orders
    ADD CONSTRAINT orders_status_fk
        FOREIGN KEY (status_id)
        REFERENCES order_statuses (status_id);

ALTER TABLE events
    ADD CONSTRAINT events_user_fk
        FOREIGN KEY (user_id)
        REFERENCES users (user_id);

ALTER TABLE events
    ADD CONSTRAINT events_type_fk
        FOREIGN KEY (event_type_id)
        REFERENCES event_types (event_type_id);

-- Проверка типа таблиц, ключа распределения и группы совместного размещения.
SELECT
    table_name,
    citus_table_type,
    distribution_column,
    colocation_id
FROM citus_tables
WHERE table_name IN (
    'public.users',
    'public.orders',
    'public.events',
    'public.order_statuses',
    'public.event_types'
)
ORDER BY table_name;
