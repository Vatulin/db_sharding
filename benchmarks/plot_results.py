"""Запуск: python benchmarks/plot_results.py (нужен matplotlib)."""

import csv
from pathlib import Path
from statistics import mean

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


results = Path(__file__).resolve().parents[1] / "results"
queries = {
    "select_user_orders": "Выборка заказов пользователя",
    "join_user_orders": "Соединение пользователей, заказов и статусов",
    "aggregate_orders": "Агрегация всех заказов",
    "insert_order": "Вставка заказа без COMMIT",
}
folders = sorted(
    (p for p in results.iterdir() if p.name == "baseline" or p.name.startswith("citus_")),
    key=lambda p: 0 if p.name == "baseline" else int(p.name.split("_")[1]),
)
data = {}
for folder in folders:
    # Если запусков несколько, используем последний завершённый.
    for summary in sorted(folder.glob("*/summary.csv"), reverse=True):
        report = summary.with_name("report.txt")
        if not report.exists() or "ОПЫТ ЗАВЕРШЁН." not in report.read_text(encoding="utf-8"):
            continue
        with summary.open(encoding="utf-8", newline="") as file:
            rows = list(csv.DictReader(file))
        values = {q: [float(r["mean_ms"]) for r in rows if r["query"] == q] for q in queries}
        if all(values.values()):
            data[folder.name] = {q: mean(times) for q, times in values.items()}
            print(f"Источник: {summary}")
            break

if not data:
    raise SystemExit("В results нет завершённых запусков с четырьмя запросами.")

fig, axes = plt.subplots(2, 2, figsize=(15, 9), layout="constrained")
for ax, (query, title) in zip(axes.flat, queries.items()):
    bars = ax.bar(list(data), [values[query] for values in data.values()], color="#3979ab")
    ax.bar_label(bars, fmt="%.3f", padding=3)
    ax.set_title(title)
    ax.set_ylabel("Среднее время, мс")
    ax.tick_params(axis="x", rotation=20)
    ax.set_axisbelow(True)
    ax.grid(axis="y", alpha=0.25)
    ax.margins(y=0.18)

fig.suptitle("Время выполнения запросов: PostgreSQL и Citus")
output = results / "comparison.png"
fig.savefig(output, dpi=160)
plt.close(fig)
print(f"График сохранён: {output}")
