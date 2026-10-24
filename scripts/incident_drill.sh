#!/usr/bin/env bash
# Incident drill: reproduce the "pricing drift" incident end to end on the local
# stack and recover from it. The write-up is docs/postmortems/2026-10-pricing-drift.md.
#
#   1. v1 serves normal traffic                          (baseline)
#   2. a price rise shifts the inputs                     (drifted traffic)
#   3. the drift job detects it and fails                 (the "page")
#   4. a hasty retrain on corrupted labels is attempted   (blocked by the quality gate)
#   5. a proper retrain on recent data is promoted        (v3)
#   6. drift check is green again against v3's profile    (recovery)
#   7. rollback rehearsal: @champion back to v1 and forward again
set -euo pipefail
cd "$(dirname "$0")/.."
PY=python3; [ -x .venv/bin/python ] && PY=.venv/bin/python

compose() { docker compose --progress quiet "$@"; }
job() { compose run --rm trainer "$@" 2>/dev/null; }
drift() { compose run --rm --entrypoint python trainer -m churn.monitoring.drift_job --bucket churn-capture --fail-on-drift 2>/dev/null; }
step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
flush_capture() { compose restart api >/dev/null 2>&1; compose up -d --wait api >/dev/null 2>&1; }
clear_capture() { compose exec -T localstack awslocal s3 rm s3://churn-capture --recursive >/dev/null; }

step "Fresh stack"
compose --profile jobs down -v >/dev/null 2>&1 || true
rm -f model/model.joblib model/metadata.json model/profile.json
compose up -d --wait localstack mlflow

step "1. Baseline: train, gate and serve v1"
job train >/dev/null && job gate >/dev/null && job export >/dev/null
compose up -d --wait api
"$PY" scripts/send_traffic.py --n 1000
flush_capture
drift && echo "drift check: OK"
clear_capture

step "2. Price rise: drifted traffic hits the API"
"$PY" scripts/send_traffic.py --n 1000 --drift 0.9
flush_capture

step "3. Scheduled drift check fails (this is the page)"
if drift; then echo "expected drift to be detected" >&2; exit 1; fi

step "4. Hasty retrain on mislabelled data: the gate must block it"
job train --label-noise 0.4 >/dev/null
if job gate; then echo "gate should have failed" >&2; exit 1; fi

step "5. Proper retrain on recent (drifted) data"
job train --drift 0.9 --data-seed 8 >/dev/null
job gate
job export >/dev/null
compose up -d --force-recreate --wait api
curl -s localhost:8000/health; echo
clear_capture

step "6. Same traffic, new model: drift check is green"
"$PY" scripts/send_traffic.py --n 1000 --drift 0.9
flush_capture
drift && echo "drift check: OK"

step "7. Rollback rehearsal"
job rollback
job rollback
echo "@champion restored"

step "Drill complete. MLflow: http://localhost:5000  API docs: http://localhost:8000/docs"
