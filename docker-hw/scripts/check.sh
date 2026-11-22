#!/usr/bin/env bash
# Автоматическая проверка восстановления (уровень 10).
# Нужны только Docker с Compose и curl.
set -Eeuo pipefail
cd "$(dirname "$0")/.."

PROJECT="hwcheck-$(date +%s)-$$"
export HOST_PORT="${HOST_PORT:-$((20000 + RANDOM % 20000))}"
export GREETING="check run"
BASE="http://127.0.0.1:${HOST_PORT}"
N="${N:-5}"
BACKUP_DIR="${BACKUP_DIR:-$PWD/backups}"
STAGE="init"
DC=(docker compose -p "$PROJECT" -f compose.yaml)

log()  { printf '[%s] %s\n' "$(date +%T)" "$*"; }
fail() { log "ОШИБКА на этапе '$STAGE': $*"; exit 1; }
cleanup() {
  local rc=$?
  log "Очистка: удаляю тестовый проект $PROJECT (контейнеры, сеть, volumes)"
  "${DC[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
  [ $rc -eq 0 ] && log "ИТОГ: УСПЕХ" || log "ИТОГ: ПРОВАЛ (код $rc)"
  exit $rc
}
trap cleanup EXIT
trap 'fail "команда завершилась с ошибкой (строка $LINENO)"' ERR

code()  { curl -s -o /dev/null -w '%{http_code}' --max-time 3 "$@" || echo 000; }
count() { curl -fsS --max-time 3 "$@" | grep -o '"count": *[0-9]*' | grep -o '[0-9]*$'; }
wait_ready() {
  local deadline=$((SECONDS + ${1:-60}))
  until [ "$(code "$BASE/readyz")" = 200 ]; do
    [ $SECONDS -lt $deadline ] || fail "сервис не стал готов за ${1:-60} с"
    sleep 1
  done
}
expect() { [ "$2" = "$3" ] || fail "$1: ожидалось $3, получено $2"; log "OK  $1 = $2"; }

STAGE="1. запуск пустого проекта"; log "$STAGE (порт $HOST_PORT)"
"${DC[@]}" up -d --wait --wait-timeout 90 >/dev/null
wait_ready 60

STAGE="2. счетчик 0 -> N"; log "$STAGE"
expect "исходный счетчик" "$(count "$BASE/")" 0
for _ in $(seq "$N"); do count -X POST "$BASE/increment" >/dev/null; done
expect "после $N POST" "$(count "$BASE/")" "$N"

STAGE="3. пересоздание контейнера app"; log "$STAGE"
"${DC[@]}" up -d --no-deps --force-recreate --wait --wait-timeout 60 app >/dev/null
wait_ready 60
expect "после пересоздания app" "$(count "$BASE/")" "$N"

STAGE="4. отключение Redis"; log "$STAGE"
"${DC[@]}" stop redis >/dev/null
expect "GET /healthz" "$(code "$BASE/healthz")" 200
expect "GET /readyz" "$(code "$BASE/readyz")" 503
expect "POST /increment" "$(code -X POST "$BASE/increment")" 503
"${DC[@]}" start redis >/dev/null
wait_ready 60
expect "GET / после запуска Redis" "$(count "$BASE/")" "$N"
expect "следующий POST" "$(count -X POST "$BASE/increment")" "$((N + 1))"

STAGE="5. резервная копия"; log "$STAGE"
mkdir -p "$BACKUP_DIR"
"${DC[@]}" stop app redis >/dev/null
VOL="${PROJECT}_redis-data"
FILE="redis-data-${PROJECT}.tar.gz"
docker run --rm -v "$VOL":/data:ro -v "$BACKUP_DIR":/backup alpine:3.20 \
  tar -czpf "/backup/$FILE" -C /data . 
[ -s "$BACKUP_DIR/$FILE" ] || fail "файл копии пуст"
log "OK  копия: $BACKUP_DIR/$FILE ($(wc -c <"$BACKUP_DIR/$FILE") байт)"
docker run --rm -v "$BACKUP_DIR":/backup alpine:3.20 tar -tzvf "/backup/$FILE"

STAGE="6. удаление проекта с volumes"; log "$STAGE"
"${DC[@]}" down -v --remove-orphans >/dev/null
docker volume inspect "$VOL" >/dev/null 2>&1 && fail "volume $VOL не удален"
log "OK  проект и volume удалены"
