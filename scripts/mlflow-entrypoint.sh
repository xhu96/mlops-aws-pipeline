#!/usr/bin/env sh
# MLflow server entrypoint. On AWS the RDS password arrives from Secrets Manager
# as DB_PASSWORD; it is URL-encoded here so any generated character is safe.
set -eu
if [ -n "${DB_HOST:-}" ]; then
  PW=$(python -c 'import os, urllib.parse; print(urllib.parse.quote(os.environ["DB_PASSWORD"], safe=""))')
  set -- --backend-store-uri "postgresql://${DB_USER}:${PW}@${DB_HOST}:5432/${DB_NAME}" "$@"
fi
exec mlflow server --host 0.0.0.0 --port 5000 "$@"
