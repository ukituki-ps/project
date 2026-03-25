#!/usr/bin/env bash
set -euo pipefail

# Конфигурация
ENVIRONMENT="${ENVIRONMENT:-production}"
BACKUP_BEFORE_MIGRATIONS="${BACKUP_BEFORE_MIGRATIONS:-0}"
SKIP_MIGRATIONS="${SKIP_MIGRATIONS:-0}"
RUN_MIGRATIONS="${RUN_MIGRATIONS:-1}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-app}"

# Логирование
log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

error() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2
}

dc() {
    docker compose "$@"
}
wait_for_db() {
    local service="postgres"
    local retries=30
    local sleep_seconds=3
    local container_id

    log "Ожидаю готовность базы данных (${service})..."

    for ((i=1; i<=retries; i++)); do
        container_id="$(dc ps -q "${service}" 2>/dev/null || true)"
        if [ -n "${container_id}" ]; then
            local status
            status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_id}" 2>/dev/null || true)"
            if [ "${status}" = "healthy" ] || [ "${status}" = "running" ]; then
                log "База данных готова"
                return 0
            fi
        fi

        sleep "${sleep_seconds}"
    done

    error "База данных не стала готовой вовремя"
    return 1
}

backup_database() {
    if ! command -v pg_dump >/dev/null 2>&1; then
        log "pg_dump не найден на хосте. Пропускаю резервное копирование."
        return 0
    fi

    local backup_dir="${PROJECT_DIR}/backups"
    local ts
    ts="$(date +'%Y%m%d_%H%M%S')"
    mkdir -p "${backup_dir}"

    log "Создаю резервную копию БД..."
    PGPASSWORD="${POSTGRES_PASSWORD}" pg_dump \
        -h "${POSTGRES_HOST:-127.0.0.1}" \
        -p "${POSTGRES_PORT:-5432}" \
        -U "${POSTGRES_USER}" \
        -d "${POSTGRES_DB}" \
        > "${backup_dir}/db_${ts}.sql"

    log "Резервная копия создана: ${backup_dir}/db_${ts}.sql"
}

run_migrations() {
    log "Запускаю миграции Alembic..."
    dc exec -T backend alembic upgrade head
    log "Миграции выполнены"
}

check_health() {
    local service="$1"
    local container_id
    local status

    container_id="$(dc ps -q "${service}" 2>/dev/null || true)"
    if [ -z "${container_id}" ]; then
        error "Сервис ${service} не найден в compose"
        return 1
    fi

    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_id}" 2>/dev/null || true)"
    if [ "${status}" = "healthy" ] || [ "${status}" = "running" ]; then
        log "Сервис ${service} в состоянии ${status}"
        return 0
    fi

    error "Сервис ${service} в некорректном состоянии: ${status:-unknown}"
    return 1
}

cleanup() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        error "Скрипт завершился с ошибкой (код: $exit_code)"
        dc logs --tail=50
    fi
    exit $exit_code
}

trap cleanup EXIT

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${PROJECT_DIR}"

# Проверка зависимостей
for cmd in docker; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        error "$cmd не установлен"
        exit 1
    fi
done

if ! dc version >/dev/null 2>&1; then
    error "Плагин docker compose недоступен"
    exit 1
fi


# Настройка compose файла
COMPOSE_FILE="docker-compose.yml"
if [ -f "docker-compose.${ENVIRONMENT}.yml" ]; then
    COMPOSE_FILE="docker-compose.yml:docker-compose.${ENVIRONMENT}.yml"
fi
export COMPOSE_FILE
export COMPOSE_PROJECT_NAME

log "Использую окружение: $ENVIRONMENT"
log "Compose файл: $COMPOSE_FILE"

# Работа с .env
if [ ! -f ".env" ]; then
    if [ -f ".env.example" ]; then
        cp .env.example .env
        log "Создан .env из .env.example"
        
        if [ "$ENVIRONMENT" = "production" ]; then
            error "Пожалуйста, обновите секреты в .env перед продакшен-деплоем"
            exit 1
        fi
    else
        error ".env файл не найден"
        exit 1
    fi
fi

# Загрузка переменных окружения
set -a
source .env
set +a

log "Загрузка образов..."
dc pull --ignore-pull-failures

log "Сборка локальных образов..."
dc build backend

log "Запуск сервисов..."
dc up -d --remove-orphans

# Ожидание готовности сервисов
wait_for_db

# Миграции
if [ "$SKIP_MIGRATIONS" = "0" ] && [ "$RUN_MIGRATIONS" = "1" ]; then
    if dc exec -T backend sh -lc "command -v alembic >/dev/null 2>&1"; then
        if [ "$BACKUP_BEFORE_MIGRATIONS" = "1" ]; then
            backup_database
        fi
        run_migrations
    else
        log "Alembic не найден. Пропускаем миграции."
    fi
fi

# Проверка здоровья
check_health backend

log "Статус стека:"
dc ps

log "Деплой успешно завершен"