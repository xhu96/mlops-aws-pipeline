# syntax=docker/dockerfile:1.7
# One Dockerfile, three targets:
#   api     - slim serving image (default)
#   trainer - training / gate / export jobs, includes MLflow
#   mlflow  - MLflow tracking server + model registry

ARG PYTHON_VERSION=3.12

FROM python:${PYTHON_VERSION}-slim AS base
ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    MLFLOW_DISABLE_TELEMETRY=true
RUN groupadd --system app && useradd --system --gid app --home-dir /app app
WORKDIR /app

FROM base AS trainer
COPY requirements/train.txt requirements/train.txt
RUN pip install -r requirements/train.txt
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-deps . && install -d -o app -g app /work
# Writable scratch dir for local MLflow runs (sqlite + artifacts) in CI.
WORKDIR /work
USER app
ENTRYPOINT ["python", "-m", "churn.pipeline"]

FROM base AS mlflow
COPY requirements/train.txt requirements/train.txt
RUN pip install -r requirements/train.txt psycopg2-binary==2.9.10
COPY scripts/mlflow-entrypoint.sh /usr/local/bin/mlflow-entrypoint
USER app
EXPOSE 5000
ENTRYPOINT ["mlflow-entrypoint"]

FROM base AS api
COPY requirements/serve.txt requirements/serve.txt
RUN pip install -r requirements/serve.txt
COPY pyproject.toml ./
COPY src ./src
RUN pip install --no-deps . && rm -rf src
# The image holds code only. The model bundle is either mounted (local compose)
# or pulled from S3 at startup at the version pinned in the ECS task definition.
ARG GIT_SHA=unknown
LABEL org.opencontainers.image.source="https://github.com/xhu96/mlops-aws-pipeline" \
      org.opencontainers.image.revision="${GIT_SHA}"
ENV MODEL_DIR=/app/model
USER app
EXPOSE 8000
HEALTHCHECK --interval=15s --timeout=3s --start-period=10s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(urllib.request.urlopen('http://127.0.0.1:8000/health').status != 200)"
CMD ["uvicorn", "churn.serving.app:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "2"]
