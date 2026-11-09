-- Запуск через psql на baseline или coordinator. Только чтение.
\set ON_ERROR_STOP on
\pset pager off
\if :{?user_id}
\else
  \set user_id 1
\endif
\if :{?row_limit}
\else
  \set row_limit 50
\endif

\echo 'Выборка заказов одного пользователя'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT order_id, user_id, status_id, total_amount, created_at
FROM public.orders
WHERE user_id = :user_id
ORDER BY created_at DESC, order_id DESC
LIMIT :row_limit;

\echo 'Соединение по ключу распределения'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT u.user_id, u.name, u.email, o.order_id,
       s.name AS status_name, o.total_amount, o.created_at
FROM public.users u
JOIN public.orders o ON o.user_id = u.user_id
JOIN public.order_statuses s ON s.status_id = o.status_id
WHERE u.user_id = :user_id
ORDER BY o.created_at DESC, o.order_id DESC
LIMIT :row_limit;

\echo 'Агрегация всех заказов'
EXPLAIN (ANALYZE, BUFFERS, VERBOSE)
SELECT o.status_id, s.name AS status_name, count(*) AS orders_count,
       sum(o.total_amount) AS total_amount,
       round(avg(o.total_amount), 2) AS average_amount,
       min(o.total_amount) AS min_amount, max(o.total_amount) AS max_amount
FROM public.orders o
JOIN public.order_statuses s ON s.status_id = o.status_id
GROUP BY o.status_id, s.name
ORDER BY o.status_id;
