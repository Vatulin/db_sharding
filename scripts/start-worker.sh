#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo 'Запуск: bash scripts/start-worker.sh --name worker-4'
  echo 'Запускайте на сервере с уже работающим координатором этого проекта.'
}

fail() {
  echo "Ошибка: $*" >&2
  exit 1
}

worker_name=''
while (($#)); do
  case "$1" in
    --name|-n)
      [[ $# -ge 2 && -n "$2" ]] || fail 'После --name требуется имя воркера.'
      [[ -z "$worker_name" ]] || fail 'Укажите --name только один раз.'
      worker_name=$2
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) fail "Неизвестный аргумент: $1" ;;
  esac
done

[[ ${#worker_name} -le 63 && "$worker_name" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] ||
  fail 'Укажите --name: 1–63 строчных латинских буквы, цифры или дефисы; дефис не может быть первым или последним.'

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"
command -v docker >/dev/null || fail 'Docker не установлен.'
compose=(docker compose --project-directory "$project_dir" -f "$project_dir/compose.yaml")
services=$("${compose[@]}" --profile '*' config --services)
if [[ "$worker_name" != 'worker-3' ]] && grep -Fxq -- "$worker_name" <<< "$services"; then
  fail "Имя $worker_name уже занято сервисом проекта. Выберите другое."
fi
coordinator=$("${compose[@]}" ps -q coordinator)
[[ -n "$coordinator" ]] || fail 'Сначала запустите координатор через Docker Compose.'
project_name=$(docker inspect --format '{{ index .Config.Labels "com.docker.compose.project" }}' "$coordinator")
compose+=(-p "$project_name")

override=''
trap 'if [[ -n "$override" ]]; then rm -f -- "$override"; fi' EXIT
if [[ "$worker_name" == 'worker-3' ]]; then
  # Сохраняем существующий сервис и его том данных.
  compose+=(--profile scale)
else
  override=$(mktemp)
  # Compose объединяет тома по пути назначения: том worker-1 заменяется отдельным.
  cat > "$override" <<EOF
services:
  "$worker_name":
    extends:
      file: "$project_dir/compose.yaml"
      service: worker-1
    volumes:
      - extra_${worker_name}_data:/var/lib/postgresql
volumes:
  extra_${worker_name}_data:
EOF
  compose+=(-f "$override")
fi

# Остальные сервисы и их контейнеры не пересоздаются.
COMPOSE_IGNORE_ORPHANS=true "${compose[@]}" up -d --wait --wait-timeout 120 --no-deps "$worker_name"
"${compose[@]}" exec -T "$worker_name" sh -c \
  'exec psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1' \
  < "$project_dir/sql/setup/01_enable_extensions.sql"
printf 'Воркер %s готов. Добавьте его по этому имени на странице «Кластер», затем запустите балансировку.\n' "$worker_name"
