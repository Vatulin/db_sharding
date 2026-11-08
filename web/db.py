"""Подключение к координатору Citus и выполнение параметризованных запросов."""

from __future__ import annotations

import os
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Iterator, Sequence

import psycopg
from dotenv import load_dotenv
from psycopg.rows import dict_row


PROJECT_ROOT = Path(__file__).resolve().parent.parent
load_dotenv(PROJECT_ROOT / ".env")


class DatabaseError(RuntimeError):
    """Ошибка соединения с БД или выполнения запроса."""


def _connection_parameters() -> dict[str, Any]:
    """Возвращает параметры подключения для Flask, запущенного в Windows."""
    return {
        "host": os.getenv("COORDINATOR_HOST", "127.0.0.1"),
        "port": int(os.getenv("COORDINATOR_PORT", "15432")),
        "dbname": os.getenv("POSTGRES_DB", "coursework"),
        "user": os.getenv("POSTGRES_USER", "postgres"),
        "password": os.getenv("POSTGRES_PASSWORD"),
        "connect_timeout": 3,
        "row_factory": dict_row,
    }


@contextmanager
def get_connection(*, autocommit: bool = False) -> Iterator[psycopg.Connection[Any]]:
    """Открывает соединение и фиксирует успешную транзакцию при выходе."""
    try:
        with psycopg.connect(**_connection_parameters(), autocommit=autocommit) as connection:
            yield connection
    except (psycopg.Error, ValueError) as error:
        raise DatabaseError(str(error)) from error


def fetch_one(
    query: str, parameters: Sequence[Any] = (),
) -> dict[str, Any] | None:
    """Выполняет запрос и возвращает первую строку либо ``None``."""
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(query, parameters)
            return cursor.fetchone()


def fetch_all(query: str, parameters: Sequence[Any] = ()) -> list[dict[str, Any]]:
    """Выполняет запрос и возвращает все его строки."""
    with get_connection() as connection:
        with connection.cursor() as cursor:
            cursor.execute(query, parameters)
            return list(cursor.fetchall())


def get_dashboard_summary() -> dict[str, int]:
    """Считывает число рабочих узлов и записей предметной области."""
    result = fetch_one(
        """
            SELECT
                (SELECT count(*) FROM citus_get_active_worker_nodes()) AS workers_count,
                (SELECT count(*) FROM users) AS users_count,
                (SELECT count(*) FROM orders) AS orders_count,
                (SELECT count(*) FROM events) AS events_count;
        """
    )

    if result is None:
        raise DatabaseError("Координатор не вернул сводные данные.")

    return {name: int(value) for name, value in result.items()}
