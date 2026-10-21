# Стенд PostgreSQL и Citus

Требуются VirtualBox и Vagrant. Виртуальная машина Ubuntu получает 4 процессора и 6 ГБ памяти; Docker и Compose устанавливает `provision.sh`.

## Первый запуск

В PowerShell из корня репозитория создайте `.env`, если его ещё нет, и задайте в нём свой `POSTGRES_PASSWORD`:

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
notepad .env
cd infrastructure
vagrant validate
vagrant up --provider=virtualbox
vagrant ssh
```

В Ubuntu запустите координатор, два рабочих узла и отдельный PostgreSQL:

```bash
cd /project
docker compose config --quiet
docker compose pull
docker compose up -d --wait
docker compose ps
```

Подключите расширение и зарегистрируйте рабочие узлы (команды используют пользователя `postgres` и базу `coursework` из `.env.example`):

```bash
for service in coordinator worker-1 worker-2; do
  docker compose exec -T "$service" \
    psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
    < sql/setup/01_enable_extensions.sql || break
done

docker compose exec -T coordinator \
  psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
  < sql/setup/02_register_workers.sql
```

Проверьте кластер: запрос должен вернуть `worker-1` и `worker-2`.

```bash
docker compose exec -T coordinator \
  psql -U postgres -d coursework \
  -c "SELECT * FROM citus_get_active_worker_nodes();"
```

Из Windows координатор доступен по адресу `127.0.0.1:15432`, отдельный PostgreSQL — `127.0.0.1:15433`.

## Повторный запуск и остановка

В PowerShell из папки `infrastructure`:

```powershell
vagrant up
vagrant ssh
```

В Ubuntu:

```bash
cd /project
docker compose up -d --wait
docker compose ps
exit
```

Выключение VM из PowerShell:

```powershell
vagrant halt
```

## Диагностика

В Ubuntu из `/project`:

```bash
docker compose ps -a
docker compose logs --tail=100 coordinator
```

В PowerShell из `infrastructure`: `vagrant status` показывает состояние VM, `vagrant reload --provision` применяет изменения конфигурации и повторяет подготовку.

`vagrant halt` сохраняет данные. `vagrant destroy` удаляет VM вместе с данными БД; `docker compose down -v` удаляет тома БД.
