#!/usr/bin/env bash
set -euo pipefail

# Отключаем буферизацию для всего скрипта
export PYTHONUNBUFFERED=1
export DOCKER_CLI_HINTS=false

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

    # Проверяем, доступен ли alembic внутри контейнера
    if ! dc exec -T backend sh -lc "command -v alembic >/dev/null 2>&1"; then
        log "alembic не найден в контейнере backend. Пропускаю миграции."
        return 0
    fi

    # Проверяем наличие конфигурационного файла alembic.ini в рабочем каталоге контейнера
    if ! dc exec -T backend sh -lc "[ -f alembic.ini ] && echo OK || echo MISSING" | grep -q OK; then
        log "Файл alembic.ini не найден в контейнере backend. Пропускаю миграции."
        return 0
    fi

    # Пытаемся выполнить миграции, но не даём скрипту падать при ошибке миграции
    if dc exec -T backend sh -lc "alembic upgrade head"; then
        log "Миграции выполнены"
        return 0
    else
        error "Не удалось выполнить миграции alembic внутри контейнера backend"
        return 1
    fi
}

run_spiff_init() {
    log "Пробую инициализацию/миграции SpiffWorkflow..."

    # Убедимся, что контейнер базы данных для Spiff готов
    if ! check_health spiff-db; then
        log "Сервис spiff-db не готов. Пропускаю инициализацию SpiffWorkflow."
        return 0
    fi

    # Проверяем, существует ли контейнер spiffworkflow
    if ! dc ps -q spiffworkflow >/dev/null 2>&1; then
        log "Контейнер spiffworkflow не запущен. Пропускаю инициализацию."
        return 0
    fi

    # Если внутри контейнера есть alembic и конфиг — пытаемся выполнить миграции
    if dc exec -T spiffworkflow sh -lc "command -v alembic >/dev/null 2>&1" >/dev/null 2>&1; then
        if dc exec -T spiffworkflow sh -lc "[ -f alembic.ini ] && echo OK || echo MISSING" | grep -q OK; then
            log "alembic найден в spiffworkflow, запускаю миграции..."
            if dc exec -T spiffworkflow sh -lc "alembic upgrade head"; then
                log "SpiffWorkflow миграции выполнены"
                return 0
            else
                error "Ошибка при выполнении миграций SpiffWorkflow внутри контейнера"
                return 1
            fi
        else
            log "alembic.ini не найден в контейнере spiffworkflow. Пропускаю миграции SpiffWorkflow."
            return 0
        fi
    fi

    log "alembic не обнаружен в контейнере spiffworkflow. Если Spiff требует ручной инициализации — выполните её вручную."
    return 0
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

# Обновление файлов из репозитория
log "Обновление из git..."
git fetch --all
git reset --hard origin/main
log "Файлы обновлены"

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
else
    # Дополняем .env недостающими переменными из .env.example
    if [ -f ".env.example" ]; then
        while IFS='=' read -r key value; do
            key="$(echo "$key" | xargs)"
            [[ -z "$key" || "$key" == \#* ]] && continue
            if ! grep -q "^${key}=" .env 2>/dev/null; then
                echo "${key}=${value}" >> .env
                log "Добавлена недостающая переменная: ${key}"
            fi
        done < .env.example
    fi
fi

# Загрузка переменных окружения
set -a
source .env
set +a

# Совместимость переменных для разных compose-конфигураций
export STORE_ENCRYPTION_KEY="${STORE_ENCRYPTION_KEY:-${NOVU_STORE_ENCRYPTION_KEY:-change_me_novu_store_key_32_chars}}"
export SPIFFWORKFLOW_BACKEND_BPMN_SPEC_ABSOLUTE_DIR="${SPIFFWORKFLOW_BACKEND_BPMN_SPEC_ABSOLUTE_DIR:-/app/process_models}"

log "Загрузка образов..."
dc pull --ignore-pull-failures

log "Сборка локальных образов..."
dc build backend

log "Остановка старых контейнеров..."
dc down --remove-orphans --timeout 30 || true

log "Запуск сервисов..."
dc up -d --force-recreate --remove-orphans

# Ожидание готовности сервисов
wait_for_db

# Миграции
if [ "$SKIP_MIGRATIONS" = "0" ] && [ "$RUN_MIGRATIONS" = "1" ]; then
    if dc exec -T backend sh -lc "command -v alembic >/dev/null 2>&1"; then
        if [ "$BACKUP_BEFORE_MIGRATIONS" = "1" ]; then
            backup_database
        fi
        run_migrations
        # Попытка инициализировать/применить миграции для SpiffWorkflow (если требуется)
        run_spiff_init
    else
        log "Alembic не найден. Пропускаем миграции."
    fi
fi

# Проверка здоровья
check_health backend

log "Статус стека:"
dc ps

log "Деплой успешно завершен"