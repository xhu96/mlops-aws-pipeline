#!/usr/bin/env bash
# Runs inside LocalStack once it is ready: create the buckets Terraform creates on AWS.
set -euo pipefail
for bucket in churn-mlflow-artifacts churn-capture; do
  awslocal s3 mb "s3://${bucket}" || true
done
