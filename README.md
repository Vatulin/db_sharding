# PostgreSQL и Citus

Учебный стенд: координатор Citus, рабочие узлы, отдельная PostgreSQL для сравнения, веб-интерфейс Flask и мониторинг Prometheus/Grafana.

## Первый запуск

Нужны VirtualBox, Vagrant и Python 3.11 или новее. VM использует 4 CPU и 6 ГБ RAM. Команды PowerShell выполняются из корня проекта `src/db_sharding`.

```powershell
if (-not (Test-Path .env)) { Copy-Item .env.example .env }
notepad .env
```

В `.env` задайте свой `POSTGRES_PASSWORD` и добавьте `GRAFANA_ADMIN_PASSWORD` с паролем Grafana. Для приведённых команд оставьте `POSTGRES_USER=postgres` и `POSTGRES_DB=coursework`.

```powershell
cd infrastructure
vagrant up --provider=virtualbox
vagrant ssh
```

Vagrant автоматически запускает `infrastructure/provision.sh`: устанавливает Docker и Compose. В Ubuntu:

```bash
cd /project
# Исправление окончаний строк после копирования файлов из Windows:
sed -i 's/\r$//' scripts/*.sh benchmarks/*.sh
bash scripts/setup.sh
```

`setup.sh` запускает БД, включает Citus, регистрирует два воркера, создаёт схему и справочники. Используйте его для первой инициализации: повторное распределение уже распределённых таблиц завершится ошибкой.

Загрузите одинаковый исходный набор в пустые предметные таблицы обеих БД:

```bash
for service in coordinator baseline; do
  docker compose exec -T "$service" \
    psql -U postgres -d coursework -v ON_ERROR_STOP=1 \
    -v users_count=10000 -v orders_count=100000 -v events_count=200000 \
    < sql/data/generate_data.sql || break
done
```

Генератор отказывается изменять непустые предметные таблицы.

## Веб-интерфейс

В отдельном PowerShell из корня проекта:

```powershell
python -m venv web/venv
.\web\venv\Scripts\python.exe -m pip install -r web/requirements.txt
.\web\venv\Scripts\python.exe -m flask --app web.app run
```

Откройте [веб-интерфейс](http://127.0.0.1:5000). «Данные» позволяют просматривать и создавать заказы; «Кластер» — управлять воркерами; «Проверки» — проверять целостность, диагностировать кластер и выполнять SQL. Команда `DELETE` в SQL-поле сохраняет удаление в базе.

Из Windows координатор доступен по `127.0.0.1:15432`, монолит — по `127.0.0.1:15433`.

## Добавление и удаление воркеров

В Ubuntu из `/project`:

```bash
bash scripts/start-worker.sh --name worker-4
```

`--name` (или `-n`) задаёт имя: строчные латинские буквы, цифры и дефисы, до 63 символов. Скрипт запускает контейнер с отдельным томом и включает Citus. После запуска в разделе «Кластер» введите то же имя, нажмите «Добавить воркер», затем «Запустить балансировку» и дождитесь завершения.

Для удаления нажмите «Освободить» в строке нужного воркера, дождитесь переноса данных и нажмите «Удалить из кластера». Контейнер и его том автоматически не удаляются.

## Эксперименты

В Ubuntu из `/project`, после загрузки данных:

```bash
# Отдельные измерения монолита и текущего кластера:
bash benchmarks/run_benchmarks.sh --target baseline
bash benchmarks/run_benchmarks.sh --target citus

# Измерения до и после расширения: используйте свободное имя воркера.
bash benchmarks/run_benchmarks.sh --target citus --add-worker worker-5

# Настройка нагрузки:
bash benchmarks/run_benchmarks.sh --target citus --clients 4 --seconds 10 --repeats 3 --user-id 1
```

По умолчанию: один клиент, три повтора по пять секунд для каждого запроса, пользователь `1`. Пользователь должен существовать. `--add-worker` сам запускает и регистрирует воркер, выполняет балансировку и оставляет его в кластере после опыта. Во время эксперимента не изменяйте данные и состав кластера вручную.

В `results/<конфигурация>/<время_запуска>/` сохраняются:

- `summary.csv` — среднее время SQL-команды в миллисекундах;
- `report.txt` — параметры, исходные замеры, планы запросов и проверки; при масштабировании также размещения шардов и диагностика переноса.

Вставки выполняются с откатом: заказы не накапливаются, но последовательность ID растёт. Время `INSERT` не включает `COMMIT`. Для сравнения используйте одинаковые данные и ограничения таблиц: текущий скрипт подготовки добавляет внешние ключи только в Citus.

## Мониторинг

В Ubuntu из `/project`:

```bash
docker compose --profile monitoring up -d --build --no-deps citus-exporter prometheus grafana
```

[Grafana](http://localhost:3000/d/citus-cluster): пользователь `admin`, первоначальный пароль из `GRAFANA_ADMIN_PASSWORD`. [Prometheus](http://localhost:9090). Список зарегистрированных воркеров обновляется автоматически при опросе; интервал сбора — 30 секунд. В вебе есть ссылка «Мониторинг».
