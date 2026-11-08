-- Только чтение. Выполняется на координаторе Citus или в baseline.
-- Сохраните результаты до и после переноса шардов для сравнения.
-- Количество строк и денежный итог сами по себе не доказывают равенство баз.
-- Справочные показатели не имеют ожидаемого значения; для нарушений ожидается 0.
WITH checks (position, check_name, value, is_violation) AS (
    SELECT 1, 'Количество пользователей', count(*)::numeric, false FROM public.users
    UNION ALL
    SELECT 2, 'Количество заказов', count(*)::numeric, false FROM public.orders
    UNION ALL
    SELECT 3, 'Количество событий', count(*)::numeric, false FROM public.events
    UNION ALL
    SELECT 4, 'Количество статусов заказов', count(*)::numeric, false FROM public.order_statuses
    UNION ALL
    SELECT 5, 'Количество типов событий', count(*)::numeric, false FROM public.event_types
    UNION ALL
    SELECT 6, 'Общая сумма заказов', coalesce(sum(total_amount), 0), false FROM public.orders
    UNION ALL
    SELECT 7, 'Заказы без пользователя', count(*)::numeric, true
    FROM public.orders o LEFT JOIN public.users u ON u.user_id = o.user_id
    WHERE u.user_id IS NULL
    UNION ALL
    SELECT 8, 'События без пользователя', count(*)::numeric, true
    FROM public.events e LEFT JOIN public.users u ON u.user_id = e.user_id
    WHERE u.user_id IS NULL
    UNION ALL
    SELECT 9, 'Заказы без допустимого статуса', count(*)::numeric, true
    FROM public.orders o LEFT JOIN public.order_statuses s ON s.status_id = o.status_id
    WHERE s.status_id IS NULL
    UNION ALL
    SELECT 10, 'События без допустимого типа', count(*)::numeric, true
    FROM public.events e LEFT JOIN public.event_types t ON t.event_type_id = e.event_type_id
    WHERE t.event_type_id IS NULL
    UNION ALL
    SELECT 11, 'Заказы с некорректной суммой', count(*)::numeric, true
    FROM public.orders
    WHERE total_amount IS NULL OR total_amount <= 0
       OR total_amount IN ('NaN'::numeric, 'Infinity'::numeric, '-Infinity'::numeric)
    UNION ALL
    SELECT 12, 'События с payload не в виде JSON-объекта', count(*)::numeric, true
    FROM public.events
    WHERE payload IS NULL OR jsonb_typeof(payload) <> 'object'
)
SELECT check_name AS "Проверка", value AS "Значение",
       CASE WHEN NOT is_violation THEN 'Справочно'
            WHEN value = 0 THEN 'OK'
            ELSE 'Нарушение' END AS "Результат"
FROM checks
ORDER BY position;
