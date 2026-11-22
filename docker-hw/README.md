# ДЗ по Docker: счетчик в контейнерах

Выполнено на 10 баллов. Код приложения в `app/` не изменен.

## Файлы

| Файл | Назначение |
| --- | --- |
| `Dockerfile` | образ на `python:3.13-slim`, процесс от UID 10001, healthcheck `/healthz` |
| `.dockerignore` | исключает из контекста сборки git, `.env`, отчеты, копии |
| `compose.sqlite.yaml` | уровень 6: одно приложение, SQLite в именованном volume `app-data` |
| `compose.yaml` | уровни 8–10: сервисы `app` и `redis` |
| `.env.example` | настраиваемые `GREETING` и `HOST_PORT` |
| `scripts/check.sh` | автоматическая проверка восстановления (уровень 10) |
| `reports/` | вывод всех проверок |

## Уровень 4: один контейнер

```sh
docker build -t docker-hw-app .
docker run -d --name counter -p 8080:8000 -e GREETING="Hello from env!" docker-hw-app
curl -s http://127.0.0.1:8080/
curl -s -X POST http://127.0.0.1:8080/increment
docker logs counter
```

Логи: [`reports/level4.txt`](reports/level4.txt).

## Уровень 6: Compose и данные

```sh
cp .env.example .env        # GREETING и HOST_PORT
docker compose -f compose.sqlite.yaml up -d --wait
curl -s -X POST http://127.0.0.1:8080/increment
docker compose -f compose.sqlite.yaml down          # контейнер удален, volume app-data остался
docker compose -f compose.sqlite.yaml up -d --wait
curl -s http://127.0.0.1:8080/                      # счетчик тот же
```

SQLite-файл `/data/counter.db` лежит в именованном volume `app-data`, поэтому переживает удаление контейнера. Вывод: [`reports/level6.txt`](reports/level6.txt).

## Уровень 8: отдельное хранилище

`compose.yaml`:

- `app`: `STORAGE=redis`, `REDIS_URL=redis://redis:6379/0` (имя сервиса, а не localhost/IP); на компьютере публикуется только порт приложения `${HOST_PORT:-8080}:8000`; запускается после того, как Redis стал healthy;
- `redis`: `redis:7.4-alpine`, порт наружу не публикуется, volume `redis-data` подключен к `/data`, запись на диск включена (`--appendonly yes` и снимки `--save 60 1`);
- healthcheck: у `app` — запрос к `/healthz`, у `redis` — `redis-cli ping`.

```sh
cp .env.example .env
docker compose up -d --wait
for i in 1 2 3 4; do curl -s -X POST http://127.0.0.1:8080/increment; done   # N = 4
docker compose down && docker compose up -d --wait                        # без -v
curl -s http://127.0.0.1:8080/                                            # count = 4
docker compose stop redis
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/healthz    # 200
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/readyz     # 503
curl -s -o /dev/null -w '%{http_code}\n' -X POST http://127.0.0.1:8080/increment  # 503
docker compose start redis
curl -s http://127.0.0.1:8080/                                            # count = 4
curl -s -X POST http://127.0.0.1:8080/increment                           # count = 5
```

Вывод: [`reports/level8.txt`](reports/level8.txt).

## Уровень 10: ограничения и проверка восстановления

Ограничения `app` в `compose.yaml`:

- `user: "10001:10001"` — процесс не от root (`id` в отчете);
- `read_only: true` + `tmpfs: /tmp` — корневая ФС только для чтения (попытка записи в отчете падает с `Read-only file system`);
- `mem_limit: 256m`, `cpus: 1.0`.

Запуск проверки (нужны только Docker с Compose и curl):

```sh
./scripts/check.sh
```

Что делает скрипт:

1. Поднимает отдельный проект `hwcheck-<время>-<pid>` на случайном порту с пустым volume и ждет готовности.
2. Проверяет счетчик `0`, делает `N=5` запросов `POST /increment` и проверяет `5`.
3. Пересоздает только контейнер `app` (`up --no-deps --force-recreate app`) и проверяет, что счетчик сохранился.
4. Останавливает Redis: `/healthz` = 200, `/readyz` и `POST /increment` = 503; запускает Redis, ждет готовности, без перезапуска `app` получает `N` и затем `N+1`.
5. Штатно останавливает `app` и `redis` и копирует весь каталог данных Redis архивом `tar -czp` (с сохранением структуры и прав) через временный контейнер `alpine` в `backups/redis-data-<проект>.tar.gz`.
6. Удаляет тестовый проект вместе с volumes (`down -v`) и проверяет, что volume исчез.

Все `curl` идут с `--max-time 3`, ожидание готовности ограничено 60–90 с. При ошибке скрипт печатает название этапа и возвращает ненулевой код. `trap` на `EXIT` удаляет только свой тестовый проект (`docker compose -p <свое имя> down -v`); фиксированных `container_name` и общих volumes нет.

Два успешных запуска подряд: [`reports/level10.txt`](reports/level10.txt).

## Примечание о сборке

В `Dockerfile` есть необязательный `ARG PIP_TRUSTED_HOST` — по умолчанию он не задан и ни на что не влияет. Он нужен только в сети с HTTPS-прокси, где я собирал образ:

```sh
docker build --network host --build-arg PIP_TRUSTED_HOST="pypi.org files.pythonhosted.org" -t docker-hw-app .
```

В обычной сети достаточно `docker compose build` или `docker compose up -d --build`.
