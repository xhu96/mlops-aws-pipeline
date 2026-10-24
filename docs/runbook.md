# Runbook

Every CloudWatch alarm links to a section below. Commands assume `ENV=dev` or `ENV=prod` and credentials for that account.

Useful links: CloudWatch dashboard `churn-$ENV`, log groups `/ecs/churn-$ENV/api` and `/ecs/churn-$ENV/jobs`.

## api-5xx

**Meaning:** the API returned more than 5 server errors per minute for 3 of the last 5 minutes.

1. Was there a deploy in the last hour? Check the Deploy workflow runs. If yes, go to [Roll back](#roll-back) first and investigate after.
2. Find the errors:
   ```
   fields @timestamp, msg, exc
   | filter level = "ERROR"
   | sort @timestamp desc | limit 50
   ```
   (Logs Insights on `/ecs/churn-$ENV/api`)
3. `prediction failed` with a stack trace usually means the input passed validation but the model rejected it: check `/model` for the version and compare the feature list with the request.
4. Task crashes (OOM, exit code 137): check the ECS service events and the memory graph on the dashboard; raise `memory` in `modules/api_service` if needed.

## api-latency

**Meaning:** p95 response time above 500 ms.

1. Check request count on the dashboard. A traffic spike should trigger autoscaling (CPU target 60%); confirm the desired count went up in the ECS service.
2. If at max capacity, raise `api_max_count` for the environment and deploy.
3. Large batches are slow by design (up to 1000 customers per request). The "Slowest requests" widget shows whether a single caller is responsible.

## unhealthy-targets

**Meaning:** the load balancer marks at least one API task unhealthy.

1. ECS service → Events. Repeated "failed health checks" right after a deploy means the circuit breaker will roll back on its own; watch it complete.
2. A task that fails at startup usually could not download its bundle: look for an S3 `404` or `AccessDenied` in the logs and check that `bundles/v<N>/` exists in the models bucket.

## data-drift

**Meaning:** the daily job found a feature whose live distribution moved away from the training data (PSI > 0.2).

This is not an outage. Predictions still work, but they may be less accurate.

1. Read the job output in `/ecs/churn-$ENV/jobs` (stream prefix `drift`): it lists PSI per feature. Is the shift explainable (pricing change, new product, marketing campaign) or a data bug upstream (a field suddenly empty, units changed)?
2. **Data bug:** fix the producer. Do not retrain on broken data.
3. **Real change:** run the Retrain workflow. The new model is trained on recent data and must still pass the gate; its bundle carries a new profile, so the next drift check compares against the new reality.
4. Confirm the next day's drift check is green.

See the [pricing drift post-mortem](postmortems/2026-10-pricing-drift.md) for a worked example.

## ml-job-failed

**Meaning:** a retrain or drift task exited with a non-zero code.

- **Retrain, exit 1 with "Quality gate: FAILED"**: the gate did its job; nothing was deployed. Read the reasons in the log. Usually a data problem; do not lower the thresholds to get it through.
- **Retrain, connection error to MLflow**: check the `mlflow` ECS service is running and healthy.
- **Drift, "skipped"** is not a failure. A crash usually means the capture bucket or bundle could not be read; check the task role.

## Roll back

The fastest path, no code change needed: run the **Deploy** workflow manually with `model_version` set to the last good version. This re-applies Terraform with that bundle and smoke-tests it.

To roll back code as well, revert the commit on `main`; the deploy pipeline does the rest.

Rolling back the registry alias in dev (so the next deploy picks the previous model):
```bash
python -m churn.pipeline rollback   # with MLFLOW_TRACKING_URI pointing at dev MLflow
```

## Open the MLflow UI in dev

MLflow has no public endpoint. Forward it to your laptop through ECS Exec / Session Manager (needs the Session Manager plugin for the AWS CLI):
```bash
TASK=$(aws ecs list-tasks --cluster churn-dev --service-name mlflow --query 'taskArns[0]' --output text)
RUNTIME=$(aws ecs describe-tasks --cluster churn-dev --tasks "$TASK" --query 'tasks[0].containers[0].runtimeId' --output text)
aws ssm start-session --target "ecs:churn-dev_${TASK##*/}_${RUNTIME}" \
  --document-name AWS-StartPortForwardingSession --parameters portNumber=5000,localPortNumber=5000
# then open http://localhost:5000
```
