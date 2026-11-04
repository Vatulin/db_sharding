"""Операции приложения для просмотра данных и создания заказа."""

from __future__ import annotations

from decimal import Decimal, InvalidOperation
from typing import Any

try:
    from .db import fetch_all, fetch_one
except ImportError:
    from db import fetch_all, fetch_one


USERS_LIMIT = 50
ORDERS_LIMIT = 100
SHARDS_LIMIT = 250
MAX_ORDER_AMOUNT = Decimal("999999999999.99")


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

    return {
        "nodes": nodes,
        "shards": shards,
        "shard_total": total,
        "shards_limited": total > len(shards),
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
