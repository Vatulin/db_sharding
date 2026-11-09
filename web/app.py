"""Минимальное Flask-приложение для просмотра состояния кластера."""

from __future__ import annotations

import os
import secrets

from flask import Flask, abort, flash, redirect, render_template, request, session, url_for

try:
    from .db import DatabaseError, get_dashboard_summary
    from .services import ValidationError, create_order, get_cluster_data, get_data, run_cluster_action, run_check_query, run_sql_query
except ImportError:
    from db import DatabaseError, get_dashboard_summary
    from services import ValidationError, create_order, get_cluster_data, get_data, run_cluster_action, run_check_query, run_sql_query


def create_app() -> Flask:
    app = Flask(__name__)
    app.config["SECRET_KEY"] = os.getenv("FLASK_SECRET_KEY") or secrets.token_hex(32)

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
        session.setdefault('cluster_token', secrets.token_hex(32))
        try:
            cluster_data = get_cluster_data()
        except DatabaseError as error:
            return (
                render_template(
                    "cluster.html",
                    database_available=False,
                    cluster=None,
                    error_message=str(error),
                ),
                503,
            )

        return render_template(
            "cluster.html",
            database_available=True,
            cluster=cluster_data,
            error_message=None,
        )

    @app.post('/cluster/<action>')
    def manage_cluster(action):
        token = session.get('cluster_token', '')
        if not token or not secrets.compare_digest(token, request.form.get('csrf_token', '')):
            abort(400, description='Форма устарела. Обновите страницу кластера.')
        # Старую форму нельзя повторно отправить после завершения операции.
        session['cluster_token'] = secrets.token_hex(32)
        try:
            message = run_cluster_action(action, request.form.get('worker_name'), request.form.get('node_id'))
        except ValidationError as error:
            flash(str(error), 'error')
        except DatabaseError:
            app.logger.exception('Ошибка административной операции %s', action)
            flash('Операция не подтверждена. Обновите состояние кластера; подробности в журнале Flask.', 'error')
        else:
            flash(message, 'success')
        return redirect(url_for('cluster'), code=303)

    @app.get("/checks")
    def checks():
        session.setdefault("checks_token", secrets.token_hex(32))
        result = None
        name = request.args.get("query")
        error_message = None
        status = 200
        if name:
            try:
                if name not in ("check_integrity", "nodes_and_shards", "activity_and_locks"):
                    raise ValidationError("Выберите проверку целостности или диагностику.")
                result = run_check_query(name, request.args)
            except ValidationError as error:
                error_message, status = str(error), 400
            except DatabaseError as error:
                error_message, status = str(error), 503
        return render_template("checks.html", result=result,
                               error_message=error_message, values=request.args), status

    @app.post("/checks/sql")
    def execute_sql():
        token = session.get("checks_token", "")
        if not token or not secrets.compare_digest(token, request.form.get("csrf_token", "")):
            abort(400, description="Форма устарела. Обновите страницу проверок.")
        session["checks_token"] = secrets.token_hex(32)
        sql_text = request.form.get("sql", "")
        result, error_message, status = None, None, 200
        try:
            result = run_sql_query(sql_text)
        except ValidationError as error:
            error_message, status = str(error), 400
        except DatabaseError as error:
            error_message, status = str(error), 400
        return render_template("checks.html", result=result, error_message=error_message,
                               values={}, sql_text=sql_text), status

    return app


app = create_app()


if __name__ == "__main__":
    app.run(host="127.0.0.1", port=5000, debug=True)
