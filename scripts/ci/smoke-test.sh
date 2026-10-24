#!/usr/bin/env bash
# Post-deploy check: the API is up, serves the expected model version and predicts.
#   scripts/ci/smoke-test.sh <base-url> <expected-model-version>
set -euo pipefail
url="$1"; expected="$2"

for _ in $(seq 1 40); do
  version=$(curl -sf "${url}/health" | jq -r .model_version || true)
  [ "$version" = "$expected" ] && break
  sleep 15
done
if [ "$version" != "$expected" ]; then
  echo "expected model v${expected}, API reports '${version}'" >&2
  exit 1
fi

curl -sf -X POST "${url}/predict" -H 'Content-Type: application/json' -d '{
  "customers": [{"tenure_months": 2, "monthly_charges": 95, "support_tickets": 4,
                 "contract_type": "month-to-month", "internet_service": "fiber",
                 "payment_method": "electronic-check"}]}' | jq -e '.predictions[0].churn_probability >= 0'
echo "smoke test passed: ${url} serves model v${expected}"
