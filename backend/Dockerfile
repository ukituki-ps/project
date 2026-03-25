# syntax=docker/dockerfile:1

FROM python:3.12-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential \
    && rm -rf /var/lib/apt/lists/*

COPY . .
RUN mkdir -p /wheels \
    && pip install --upgrade pip \
    && if [ -f requirements.txt ]; then pip wheel --no-cache-dir --wheel-dir /wheels -r requirements.txt; fi

FROM python:3.12-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/home/appuser/.local/bin:${PATH}"

WORKDIR /app

RUN useradd --create-home --shell /bin/bash appuser

COPY --from=builder /wheels /wheels
COPY . .
RUN if [ -f requirements.txt ]; then \
        if [ "$(ls -A /wheels 2>/dev/null)" ]; then \
            pip install --no-cache-dir --no-index --find-links=/wheels -r requirements.txt; \
        else \
            pip install --no-cache-dir -r requirements.txt; \
        fi; \
    fi \
    && rm -rf /wheels

RUN chown -R appuser:appuser /app
USER appuser

EXPOSE 8000

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]


