# Отчет о проверках

Полный вывод команд — в каталоге `reports/`.

- **Уровень 4** ([level4.txt](reports/level4.txt)): образ собран, контейнер запущен с `-p 28080:8000` и `GREETING="Hello from env!"`; счетчик 0 → 1 → 2, GET не увеличивает; приложены `docker logs`.
- **Уровень 6** ([level6.txt](reports/level6.txt)): 3 POST → `count: 3`; `docker compose down` (без `-v`), volume `app-data` остался; после `up -d` GET вернул `count: 3`.
- **Уровень 8** ([level8.txt](reports/level8.txt)): N = 4 после 4 POST; после `down` и `up -d` GET вернул 4. После `stop redis`: `/healthz` 200, `/readyz` 503, `POST /increment` 503. После `start redis` без перезапуска app: GET 4, следующий POST 5.
- **Уровень 10** ([level10.txt](reports/level10.txt)): `id` в app — `uid=10001`; запись в `/app` — `Read-only file system`; `docker inspect`: `ReadonlyRootfs=true Memory=268435456 NanoCpus=1000000000`. `./scripts/check.sh` прошел два раза подряд (оба раза «ИТОГ: УСПЕХ», код 0).
