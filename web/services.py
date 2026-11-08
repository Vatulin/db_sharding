"""Операции приложения для просмотра данных и создания заказа."""

from __future__ import annotations

from decimal import Decimal, InvalidOperation
from pathlib import Path
from time import perf_counter
from typing import Any

try:
    from .db import fetch_all, fetch_one, get_connection
except ImportError:
    from db import fetch_all, fetch_one, get_connection


USERS_LIMIT = 50
ORDERS_LIMIT = 100
SHARDS_LIMIT = 250
MAX_ORDER_AMOUNT = Decimal("999999999999.99")
QUERY_SQL = Path(__file__).resolve().parent.parent / "sql" / "queries"
CHECK_QUERIES = {
    "select_user_orders": "Заказы пользователя",
    "join_user_orders": "Пользователь, заказы и статусы",
    "aggregate_orders": "Суммы и количество заказов по статусам",
    "insert_order": "Создание заказа",
}


def run_check_query(name: str, values: Any) -> dict[str, Any]:
    """Выполняет фиксированный SQL-файл с параметрами драйвера."""
    if name not in CHECK_QUERIES:
        raise ValidationError("Неизвестный запрос.")
    parameters = {}
    if name != "aggregate_orders":
        parameters["user_id"] = _parse_positive_integer(values.get("user_id"), "ID пользователя")
        if parameters["user_id"] > 9223372036854775807:
            raise ValidationError("ID пользователя превышает диапазон bigint.")
    if name in ("select_user_orders", "join_user_orders"):
        parameters["row_limit"] = _parse_positive_integer(values.get("row_limit", "50"), "Лимит строк")
        if parameters["row_limit"] > 100:
            raise ValidationError("Можно вывести не более 100 строк.")
    if name == "insert_order":
        parameters["status_id"] = _parse_positive_integer(values.get("status_id"), "ID статуса")
        if parameters["status_id"] > 32767:
            raise ValidationError("ID статуса превышает диапазон smallint.")
        parameters["total_amount"] = _parse_order_amount(values.get("total_amount"))

    # Файлы содержат числовые параметры psql. Меняем только известные маркеры,
    # значения передаём отдельно драйверу; комментарии не являются частью запроса.
    source = (QUERY_SQL / f"{name}.sql").read_text(encoding="utf-8")
    query = "\n".join(line for line in source.splitlines() if not line.lstrip().startswith("--"))
    for key in parameters:
        query = query.replace(f":{key}", f"%({key})s")
    with get_connection() as connection:
        connection.execute("SET LOCAL statement_timeout = '15s'")
        started = perf_counter()
        with connection.cursor() as cursor:
            cursor.execute(query, parameters)
            columns = [column.name for column in cursor.description]
            rows = cursor.fetchall()
        connection.commit()
        elapsed_ms = (perf_counter() - started) * 1000
    return {
        "name": name,
        "title": CHECK_QUERIES[name],
        "columns": columns,
        "rows": [[str(row[column]) if row[column] is not None else "NULL"
                  for column in columns] for row in rows],
        "elapsed_ms": round(elapsed_ms, 3),
    }


CLUSTER_SQL = Path(__file__).resolve().parent.parent / 'sql' / 'cluster'
CLUSTER_ACTIONS = {
    'add': ('add_worker.sql', 'worker-3 зарегистрирован. Теперь можно запустить балансировку.'),
    'rebalance': ('rebalance.sql', 'Фоновая балансировка запущена. Обновляйте состояние до её завершения.'),
    'remove': ('remove_worker.sql', 'worker-3 исключён из кластера. Его контейнер теперь можно остановить.'),
}


def run_cluster_action(action: str) -> str:
    """Исполняет только разрешённый SQL-файл, отдельными командами в autocommit."""
    if action not in CLUSTER_ACTIONS:
        raise ValidationError('Неизвестная операция управления кластером.')
    filename, message = CLUSTER_ACTIONS[action]
    script = (CLUSTER_SQL / filename).read_text(encoding='utf-8')
    with get_connection(autocommit=True) as connection:
        with connection.cursor() as cursor:
            # Сессионная блокировка сериализует административные запросы Flask.
            cursor.execute('SELECT pg_try_advisory_lock(824731, 8) AS acquired')
            if not cursor.fetchone()['acquired']:
                raise ValidationError('Другая операция управления уже выполняется.')
            try:
                for statement in script.split('-- step\n'):
                    if statement.strip():
                        cursor.execute(statement)
            finally:
                cursor.execute('SELECT pg_advisory_unlock(824731, 8)')
    return message


class ValidationError(ValueError):
    """Ошибка в значении, переданном из формы или строки запроса."""


def _parse_positive_integer(value: str | None, field_name: str) -> int:
    try:
        parsed_value = int(value or "")
    except ValueError as error:
        raise ValidationError(f"Поле «{field_name}» должно содержать целое число.") from error

    if parsed_value <= 0:
        raise ValidationError(f"Поле «{field_name}» должно быть больше нуля.")

    return parsed_value


def _parse_order_amount(value: str | None) -> Decimal:
    try:
        amount = Decimal((value or "").replace(",", "."))
    except InvalidOperation as error:
        raise ValidationError("Сумма заказа должна быть числом.") from error

    if not amount.is_finite() or amount <= 0:
        raise ValidationError("Сумма заказа должна быть больше нуля.")
    if amount > MAX_ORDER_AMOUNT:
        raise ValidationError("Сумма заказа превышает допустимый предел.")
    if amount.quantize(Decimal("0.01")) != amount:
        raise ValidationError("Сумма заказа указывается с точностью до копеек.")

    return amount


def get_data(user_id_text: str | None) -> dict[str, Any]:
    """Возвращает пользователей, заказы и статусы для страницы данных."""
    selected_user_id = None
    if user_id_text and user_id_text.strip():
        selected_user_id = _parse_positive_integer(user_id_text, "Идентификатор пользователя")

    statuses = fetch_all(
        "SELECT status_id, name FROM order_statuses ORDER BY status_id;"
    )

    if selected_user_id is None:
        users = fetch_all(
            """
                SELECT user_id, name, email, created_at
                FROM users
                ORDER BY user_id
                LIMIT %s;
            """,
            (USERS_LIMIT,),
        )
        orders = fetch_all(
            """
                SELECT o.user_id, o.order_id, s.name AS status_name,
                       o.total_amount, o.created_at
                FROM orders AS o
                JOIN order_statuses AS s USING (status_id)
                ORDER BY o.created_at DESC, o.user_id, o.order_id DESC
                LIMIT %s;
            """,
            (ORDERS_LIMIT,),
        )
    else:
        users = fetch_all(
            """
                SELECT user_id, name, email, created_at
                FROM users
                WHERE user_id = %s;
            """,
            (selected_user_id,),
        )
        orders = fetch_all(
            """
                SELECT o.user_id, o.order_id, s.name AS status_name,
                       o.total_amount, o.created_at
                FROM orders AS o
                JOIN order_statuses AS s USING (status_id)
                WHERE o.user_id = %s
                ORDER BY o.created_at DESC, o.order_id DESC
                LIMIT %s;
            """,
            (selected_user_id, ORDERS_LIMIT),
        )

    return {
        "selected_user_id": selected_user_id,
        "statuses": statuses,
        "users": users,
        "orders": orders,
    }


def get_cluster_data() -> dict[str, Any]:
    """Возвращает метаданные узлов и размещений шардов Citus."""
    nodes = fetch_all(
        """
            SELECT
                nodeid,
                groupid,
                nodename,
                nodeport,
                noderole,
                isactive,
                shouldhaveshards
            FROM pg_dist_node
            ORDER BY groupid, nodeid;
        """
    )
    shard_total = fetch_one("SELECT count(*) AS count FROM citus_shards;")
    shards = fetch_all(
        """
            SELECT
                table_name,
                shardid,
                shard_name,
                citus_table_type,
                nodename,
                nodeport,
                pg_size_pretty(shard_size) AS shard_size
            FROM citus_shards
            ORDER BY table_name, shardid, nodename, nodeport
            LIMIT %s;
        """,
        (SHARDS_LIMIT,),
    )

    total = int(shard_total["count"]) if shard_total else 0
    jobs = fetch_all('SELECT * FROM citus_rebalance_status();')
    busy = any(str(job['state']) not in ('finished', 'failed', 'cancelled') for job in jobs)
    third_node = next((node for node in nodes
                       if node['nodename'] == 'worker-3' and node['nodeport'] == 5432), None)

    return {
        "nodes": nodes,
        "shards": shards,
        "shard_total": total,
        "shards_limited": total > len(shards),
        "jobs": jobs,
        "busy": busy,
        "third_node": third_node,
    }


def create_order(
    user_id_text: str | None,
    status_id_text: str | None,
    total_amount_text: str | None,
) -> dict[str, int]:
    """Проверяет входные данные и добавляет заказ существующему пользователю."""
    user_id = _parse_positive_integer(user_id_text, "Идентификатор пользователя")
    status_id = _parse_positive_integer(status_id_text, "Статус")
    total_amount = _parse_order_amount(total_amount_text)

    user = fetch_one("SELECT user_id FROM users WHERE user_id = %s;", (user_id,))
    if user is None:
        raise ValidationError("Пользователь с указанным идентификатором не найден.")

    status = fetch_one(
        "SELECT status_id FROM order_statuses WHERE status_id = %s;",
        (status_id,),
    )
    if status is None:
        raise ValidationError("Выбранный статус не существует.")

    created_order = fetch_one(
        """
            INSERT INTO orders (user_id, status_id, total_amount)
            VALUES (%s, %s, %s)
            RETURNING user_id, order_id;
        """,
        (user_id, status_id, total_amount),
    )
    if created_order is None:
        raise RuntimeError("Не удалось получить созданный заказ.")

    return {
        "user_id": int(created_order["user_id"]),
        "order_id": int(created_order["order_id"]),
    }
