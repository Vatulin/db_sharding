-- Выполняется на координаторе и в монолитной БД PostgreSQL
-- после 03_create_schema.sql. Повторный запуск обновляет названия, не создавая повторных строк.

BEGIN;

INSERT INTO order_statuses (status_id, name)
VALUES
    (1, 'Создан'),
    (2, 'Оплачен'),
    (3, 'Выполнен'),
    (4, 'Отменён')
ON CONFLICT (status_id) DO UPDATE
SET name = EXCLUDED.name;

INSERT INTO event_types (event_type_id, name)
VALUES
    (1, 'Вход в систему'),
    (2, 'Просмотр товара'),
    (3, 'Создание заказа'),
    (4, 'Оплата заказа')
ON CONFLICT (event_type_id) DO UPDATE
SET name = EXCLUDED.name;

COMMIT;
