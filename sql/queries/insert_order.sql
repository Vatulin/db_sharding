-- psql / pgbench: user_id=1, status_id=1, total_amount=1250.50.
-- Все параметры числовые. Неверный пользователь или статус: INSERT 0 0.
-- Неположительную сумму отклоняет CHECK таблицы. ID выдаёт identity.
INSERT INTO public.orders (user_id, status_id, total_amount)
SELECT u.user_id, s.status_id, :total_amount
FROM public.users AS u
CROSS JOIN public.order_statuses AS s
WHERE u.user_id = :user_id AND s.status_id = :status_id
RETURNING user_id, order_id, status_id, total_amount, created_at;
