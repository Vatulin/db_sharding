#!/usr/bin/env bash
set -euo pipefail

cd /project

echo "1/5. Запуск контейнеров"
docker compose up -d --wait
docker compose ps

echo "2/5. Подключение Citus на координаторе и рабочих узлах"
for service in coordinator worker-1 worker-2; do
  docker compose exec -T "$service" \
    psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
    < sql/setup/01_enable_extensions.sql
done

echo "3/5. Регистрация и проверка узлов"
docker compose exec -T coordinator \
  psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
  < sql/setup/02_register_workers.sql

echo "4/5. Создание схемы и справочников"
for service in coordinator baseline; do
  docker compose exec -T "$service" \
    psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
    < sql/setup/03_create_schema.sql

  docker compose exec -T "$service" \
    psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
    < sql/setup/04_seed_reference_data.sql
done

echo "5/5. Распределение таблиц"
docker compose exec -T coordinator \
  psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
  < sql/setup/05_distribute_tables.sql

echo "Проверка распределения"
docker compose exec -T coordinator \
  psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
  -c "SELECT table_name, citus_table_type, distribution_column, colocation_id, shard_count FROM citus_tables ORDER BY table_name;"