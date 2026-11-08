-- psql: -v user_id=1 -v row_limit=50; pgbench: переменные с теми же именами.
-- Параметры числовые. Для psycopg используйте его параметры %s.
SELECT order_id, user_id, status_id, total_amount, created_at
FROM public.orders
WHERE user_id = :user_id
ORDER BY created_at DESC, order_id DESC
LIMIT :row_limit;
