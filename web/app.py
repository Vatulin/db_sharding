"""Минимальное Flask-приложение для просмотра состояния кластера."""

from __future__ import annotations

import os

from flask import Flask, flash, redirect, render_template, request, url_for

try:
    from .db import DatabaseError, get_dashboard_summary
    from .services import ValidationError, create_order, get_data
except ImportError:
    from db import DatabaseError, get_dashboard_summary
    from services import ValidationError, create_order, get_data


def create_app() -> Flask:
    app = Flask(__name__)
    app.config["SECRET_KEY"] = os.getenv("FLASK_SECRET_KEY", "local-development-key")

    @app.get("/")
    def index():
        try:
            summary = get_dashboard_summary()
        except DatabaseError as error:
            return (
                render_template(
                    "index.html",
                    database_available=False,
                    summary=None,
                    error_message=str(error),
                ),
                503,
            )

        return render_template(
            "index.html",
            database_available=True,
            summary=summary,
            error_message=None,
        )

    @app.get("/data")
    def data():
        try:
            page_data = get_data(request.args.get("user_id"))
        except ValidationError as error:
            flash(str(error), "error")
            return redirect(url_for("data"))
        except DatabaseError as error:
            return (
                render_template(
                    "data.html",
                    database_available=False,
                    data=None,
                    error_message=str(error),
                ),
                503,
            )

        return render_template(
            "data.html",
            database_available=True,
            data=page_data,
            error_message=None,
        )

    @app.post("/orders")
    def add_order():
        user_id = request.form.get("user_id")

        try:
            order = create_order(
                user_id,
                request.form.get("status_id"),
                request.form.get("total_amount"),
            )
        except ValidationError as error:
            flash(str(error), "error")
        except DatabaseError as error:
            flash(f"Не удалось создать заказ: {error}", "error")
        else:
            flash(
                f"Заказ № {order['order_id']} для пользователя {order['user_id']} создан.",
                "success",
            )

        return redirect(url_for("data", user_id=user_id))

    @app.get("/cluster")
    def cluster():
        return render_template("cluster.html")

    @app.get("/checks")
    def checks():
        return render_template("checks.html")

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
