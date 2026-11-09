#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
Запуск на сервере из каталога проекта:
  bash benchmarks/run_benchmarks.sh --target baseline
  bash benchmarks/run_benchmarks.sh --target citus
  bash benchmarks/run_benchmarks.sh --target citus --add-worker worker-4

Параметры: --clients 1 --seconds 5 --repeats 3 --user-id 1
Нужны работающие контейнеры и заранее загруженные одинаковые данные.
psql и pgbench запускаются внутри выбранного контейнера, подключение локальное.
Время: среднее время SQL-команды в мс по pgbench -r, без запуска Docker.
INSERT выполняется с ROLLBACK: строки не накапливаются, но последовательность ID растёт.
Каждый сценарий предваряется одним прогревочным выполнением.
--add-worker запускает и регистрирует новый воркер, оставляет его в кластере.
На время опыта не изменяйте данные и состав кластера через другие подключения.
Результаты: summary.csv и report.txt в новом каталоге results/.
HELP
}
fail() { echo "Ошибка: $*" >&2; exit 1; }

target=citus
clients=1
seconds=5
repeats=3
user_id=1

worker=''
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0 ;;
    --target|--clients|--seconds|--repeats|--user-id|--add-worker)
      [[ $# -ge 2 && -n "$2" ]] || fail "Нет значения для $1"
      case "$1" in
        --target) target=$2 ;; --clients) clients=$2 ;; --seconds) seconds=$2 ;;
        --repeats) repeats=$2 ;; --user-id) user_id=$2 ;; --add-worker) worker=$2 ;;
      esac
      shift 2 ;;
    *) fail "Неизвестный аргумент: $1" ;;
  esac
done

[[ "$target" == baseline || "$target" == citus ]] || fail '--target: baseline или citus'
for number in "$clients" "$seconds" "$repeats" "$user_id"; do
  [[ "$number" =~ ^[1-9][0-9]*$ ]] || fail 'Числовые параметры должны быть положительными целыми.'
done

if [[ -n "$worker" ]]; then
  [[ "$target" == citus ]] || fail '--add-worker доступен только для Citus.'
  [[ ${#worker} -le 63 && "$worker" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail 'Недопустимое имя воркера.'
fi

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
service=coordinator
[[ "$target" == baseline ]] && service=baseline
compose=(docker compose --project-directory "$root" -f "$root/compose.yaml")

psql_db() {
  "${compose[@]}" exec -T "$service" sh -c \
    'export LC_ALL=C; exec psql -X -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -P pager=off "$@"' sh \
    -v user_id="$user_id" -v row_limit=50 -v status_id=1 -v total_amount=1250.50 "$@"
}

scalar() { psql_db -Atq -c "$1"; }

workers=0
if [[ "$target" == citus ]]; then
  [[ $(scalar "SELECT count(*) FROM citus_rebalance_status() WHERE state::text NOT IN ('finished','failed','cancelled')") == 0 ]] || fail 'Сначала завершите текущую балансировку.'
  workers=$(scalar "SELECT count(*) FROM pg_dist_node WHERE groupid > 0 AND noderole='primary' AND isactive AND shouldhaveshards")
  if [[ -n "$worker" ]]; then
    [[ $(scalar "SELECT count(*) FROM pg_dist_node WHERE nodename='$worker'") == 0 ]] || fail 'Выбранный воркер уже зарегистрирован.'
  fi
fi

[[ $(scalar "SELECT count(*) FROM users WHERE user_id=$user_id") == 1 ]] || fail 'Загрузите данные или выберите существующий --user-id.'
[[ $(scalar 'SELECT count(*) FROM order_statuses WHERE status_id=1') == 1 ]] || fail 'Нет статуса заказа 1.'
"${compose[@]}" exec -T "$service" pgbench --version
label=baseline
[[ "$target" == citus ]] && label="citus_${workers}_workers"
[[ -n "$worker" ]] && label=rebalance

mkdir -p "$root/results/$label"
out=$(mktemp -d "$root/results/$label/$(date -u +%Y%m%dT%H%M%SZ)_XXXXXX")
report="$out/report.txt"
summary="$out/summary.csv"
printf 'phase,query,repeat,mean_ms\n' > "$summary"

load_pid=''
on_exit() {
  code=$?
  if [[ -n "$load_pid" ]]; then wait "$load_pid" || true; fi
  if ((code != 0)); then
    printf '\nОПЫТ НЕ ЗАВЕРШЁН. Код выхода: %s. Состав кластера автоматически не откатывается.\n' "$code" >> "$report"
  fi
}
trap on_exit EXIT
exec 2> >(tee -a "$report" >&2)
{
  printf 'Начало UTC: %s\nКонфигурация: %s\nКлиентов: %s; секунд на повтор: %s; повторов: %s; user_id: %s\n' "$(date -u +%FT%TZ)" "$label" "$clients" "$seconds" "$repeats" "$user_id"
  echo 'Время в CSV: среднее время одной SQL-команды из pgbench -r. INSERT без COMMIT, с последующим откатом.'
  echo 'Сценарии: select_user_orders — выборка; join_user_orders — соединение; aggregate_orders — агрегация; insert_order — вставка.'
  echo 'Фазы before/after — до/после расширения; rebalance_window — чтение рядом с запуском переноса; rebalance_total — полное время ожидания переноса.'
  echo 'Прогрев: одно выполнение каждого сценария; перед каждой серией выполняется ANALYZE.'
  echo 'Проверки целостности и контрольные SELECT выполняются вне замеров. Равенство проверок не доказывает полного равенства всех строк.'
  psql_db -c 'SELECT version(); SELECT extname, extversion FROM pg_extension;'
  psql_db -c "SELECT conrelid::regclass AS table_name, conname, pg_get_constraintdef(oid) FROM pg_constraint WHERE conrelid IN ('users'::regclass,'orders'::regclass,'events'::regclass) ORDER BY 1,2;"
  echo 'Видимые из контейнера CPU и память (общие ресурсы VM, не выделенные лимиты контейнера):'
  "${compose[@]}" exec -T "$service" sh -c 'getconf _NPROCESSORS_ONLN; head -n 3 /proc/meminfo'
} >> "$report"
echo "Результаты: $out"

query_script() {
  [[ "$1" != insert_order ]] || echo 'BEGIN;'
  cat "$root/sql/queries/$1.sql"
  echo
  [[ "$1" != insert_order ]] || echo 'ROLLBACK;'
}
measure() {
  local phase=$1 query=$2 repeat=$3 raw ms failed
  raw=$(query_script "$query" | "${compose[@]}" exec -T "$service" sh -c \
    'export LC_ALL=C PGAPPNAME=coursework_benchmark; exec pgbench -U "$POSTGRES_USER" -d "$POSTGRES_DB" "$@"' sh \
    -n -r --exit-on-abort -c "$clients" -T "$seconds" -D user_id="$user_id" -D row_limit=50 \
    -D status_id=1 -D total_amount=1250.50 -f /dev/stdin)

  printf '\n[%s / %s / повтор %s]\n%s\n' "$phase" "$query" "$repeat" "$raw" >> "$report"
  failed=$(awk '/^number of failed transactions:/ {print $5}' <<< "$raw")
  [[ "$failed" == 0 ]] || fail "Сценарий $query содержит ошибки; см. report.txt."
  ms=$(awk '$1 ~ /^[0-9]+([.][0-9]+)?$/ && / (SELECT|INSERT) / {print $1; exit}' <<< "$raw")
  [[ -n "$ms" ]] || fail "Не удалось получить время $query; см. report.txt."
  printf '%s,%s,%s,%s\n' "$phase" "$query" "$repeat" "$ms" >> "$summary"
  printf '%s: %s, повтор %s — %s мс\n' "$phase" "$query" "$repeat" "$ms"
}

series() {
  local phase=$1 query repeat
  psql_db -c 'ANALYZE users; ANALYZE orders; ANALYZE events;' >> "$report"
  for query in select_user_orders join_user_orders aggregate_orders insert_order; do
    query_script "$query" | psql_db -q > /dev/null
    for ((repeat=1; repeat<=repeats; repeat++)); do measure "$phase" "$query" "$repeat"; done
  done
  printf '\nПЛАНЫ ЗАПРОСОВ: %s\n' "$phase" >> "$report"
  psql_db < "$root/benchmarks/explain_queries.sql" >> "$report"
}

snapshot() {
  psql_db -Atq < "$root/sql/checks/check_integrity.sql"
  for query in select_user_orders join_user_orders aggregate_orders; do
    psql_db -Atq < "$root/sql/queries/$query.sql"
  done
}

placements() {
  psql_db < "$root/sql/monitoring/nodes_and_shards.sql"
}

before=$(snapshot)
printf '\nПРОВЕРКИ ДО ОПЫТА\n%s\n' "$before" >> "$report"
[[ "$before" != *'Нарушение'* ]] || fail 'Исходные данные не прошли проверку целостности.'
if [[ -z "$worker" ]]; then
  series "$label"
else
  printf '\nРАЗМЕЩЕНИЕ ДО ДОБАВЛЕНИЯ\n' >> "$report"
  placements >> "$report"
  series "before_${workers}_workers"
  bash "$root/scripts/start-worker.sh" --name "$worker" >> "$report"
  # Имя выше ограничено буквами, цифрами и дефисами; значения SQL передаёт psql.
  psql_db -v worker="$worker" >> "$report" <<'SQL'
SELECT pg_advisory_lock(824731, 8);
SELECT citus_add_node(:'worker', 5432);
SELECT pg_advisory_unlock(824731, 8);
SQL
  # Одновременно с переносом идёт чтение. Его интервал может быть длиннее переноса.
  measure rebalance_window aggregate_orders 1 &
  load_pid=$!
  started=$(date +%s%3N)
  psql_db < "$root/sql/cluster/rebalance.sql" >> "$report"
  job=$(scalar 'SELECT max(job_id) FROM citus_rebalance_status()')
  printf '\nАКТИВНОСТЬ ПОСЛЕ ЗАПУСКА БАЛАНСИРОВКИ\n' >> "$report"
  # Диагностика не должна прерывать сам эксперимент при кратковременной ошибке узла.
  if ! { echo "SET statement_timeout='15s';"; cat "$root/sql/monitoring/activity_and_locks.sql"; } | psql_db >> "$report"; then
    echo 'Снимок активности получить не удалось; см. сообщение об ошибке выше.' >> "$report"
  fi
  psql_db -c "SET statement_timeout='10min'; SELECT citus_rebalance_wait();" >> "$report"
  elapsed=$(( $(date +%s%3N) - started ))
  wait "$load_pid"
  load_pid=''
  printf 'rebalance_window,rebalance_total,1,%s\n' "$elapsed" >> "$summary"
  printf '\nБалансировка: %s мс от запуска до завершения ожидания (включая обращения Docker и снимок диагностики).\nЧтение rebalance_window: фиксированное окно %s с, может захватывать время до/после переноса.\n' "$elapsed" "$seconds" >> "$report"
  psql_db -c 'SELECT * FROM citus_rebalance_status();' >> "$report"
  [[ $(scalar "SELECT state FROM citus_rebalance_status() WHERE job_id=$job") == finished ]] || fail 'Балансировка не завершилась успешно.'
  [[ $(scalar "SELECT count(*) FROM citus_shards WHERE nodename='$worker' AND table_name::text IN ('users','public.users','orders','public.orders','events','public.events')") != 0 ]] || fail 'Новый воркер не получил распределённые шарды.'
  printf '\nРАЗМЕЩЕНИЕ ПОСЛЕ БАЛАНСИРОВКИ\n' >> "$report"
  placements >> "$report"
  series "after_$((workers + 1))_workers"
fi

after=$(snapshot)
printf '\nПРОВЕРКИ ПОСЛЕ ОПЫТА\n%s\n' "$after" >> "$report"
[[ "$before" == "$after" ]] || fail 'Контрольные результаты до и после различаются; см. report.txt.'
echo 'ОПЫТ ЗАВЕРШЁН. Проверки и контрольные запросы до/после совпали.' | tee -a "$report"
echo "Время запросов: $summary"
