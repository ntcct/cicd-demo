# syntax=docker/dockerfile:1

# ---- Build stage: install deps into a venv ----
FROM python:3.11-slim AS build

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1

WORKDIR /app

# Create an isolated virtualenv we can copy wholesale into the runtime image.
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY pyproject.toml ./
# Install only runtime dependencies (not dev extras).
RUN pip install --upgrade pip && pip install .

COPY app ./app

# ---- Runtime stage: slim, non-root ----
FROM python:3.11-slim AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    APP_ENV=local \
    APP_VERSION=0.0.0-dev

# Create an unprivileged user. Running as non-root is a baseline prod control.
RUN groupadd --system app && useradd --system --gid app --no-create-home appuser

WORKDIR /app
COPY --from=build /opt/venv /opt/venv
COPY --from=build /app/app ./app

USER appuser

EXPOSE 8000

# Simple container-level healthcheck mirrors the k8s liveness probe.
HEALTHCHECK --interval=30s --timeout=3s --retries=3 \
    CMD python -c "import urllib.request,sys; sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz').status==200 else 1)"

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000"]
