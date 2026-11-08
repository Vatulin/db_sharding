-- psql / pgbench: user_id=1, row_limit=50.
-- Соединение по ключу распределения; запрос одного пользователя.
SELECT u.user_id, u.name, u.email, o.order_id,
       s.name AS status_name, o.total_amount, o.created_at
FROM public.users AS u
JOIN public.orders AS o ON o.user_id = u.user_id
JOIN public.order_statuses AS s ON s.status_id = o.status_id
WHERE u.user_id = :user_id
ORDER BY o.created_at DESC, o.order_id DESC
LIMIT :row_limit;
