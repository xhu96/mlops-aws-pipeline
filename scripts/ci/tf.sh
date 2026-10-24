#!/usr/bin/env bash
# Terraform wrapper used by the deploy workflow.
#   scripts/ci/tf.sh <env> init|apply|output [args...]
# Needs: AWS_ACCOUNT_ID, IMAGE_TAG, MODEL_VERSION (apply only).
set -euo pipefail
env="$1"; cmd="$2"; shift 2
dir="infra/terraform/envs/${env}"
registry="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION:-eu-west-2}.amazonaws.com"

case "$cmd" in
  init)
    terraform -chdir="$dir" init -input=false -backend-config="bucket=churn-tfstate-${AWS_ACCOUNT_ID}"
    ;;
  apply)
    terraform -chdir="$dir" apply -input=false -auto-approve \
      -var "ecr_registry=${registry}" \
      -var "api_image_tag=${IMAGE_TAG}" \
      -var "trainer_image_tag=${IMAGE_TAG}" \
      -var "mlflow_image_tag=${IMAGE_TAG}" \
      -var "model_version=${MODEL_VERSION}" \
      ${ALERT_EMAIL:+-var "alert_emails=[\"${ALERT_EMAIL}\"]"} "$@"
    ;;
  output)
    terraform -chdir="$dir" output -raw "$@"
    ;;
  *)
    echo "unknown command: $cmd" >&2; exit 2
    ;;
esac
