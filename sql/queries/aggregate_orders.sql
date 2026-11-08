-- Без параметров; обрабатывает все шарды, группирует заказы по статусу.
-- Один и тот же запрос используется в Citus и baseline.
SELECT o.status_id, s.name AS status_name, count(*) AS orders_count,
       sum(o.total_amount) AS total_amount,
       round(avg(o.total_amount), 2) AS average_amount,
       min(o.total_amount) AS min_amount, max(o.total_amount) AS max_amount
FROM public.orders AS o
JOIN public.order_statuses AS s ON s.status_id = o.status_id
GROUP BY o.status_id, s.name
ORDER BY o.status_id;
