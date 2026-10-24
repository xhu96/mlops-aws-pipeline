#!/usr/bin/env bash
# Run one ML job (retrain | drift) as an ECS Fargate task, stream its logs and
# exit with the container's exit code, so a failed quality gate fails the step.
#   scripts/ci/run-job.sh <env> <job>
set -euo pipefail
env="$1"; job="$2"
tf() { scripts/ci/tf.sh "$env" output "$@"; }

cluster=$(tf cluster_name)
family=$(terraform -chdir="infra/terraform/envs/${env}" output -json job_task_families | jq -r ".${job}")
subnets=$(terraform -chdir="infra/terraform/envs/${env}" output -json subnet_ids | jq -r 'join(",")')
sg=$(tf jobs_security_group_id)

task_arn=$(aws ecs run-task --cluster "$cluster" --task-definition "$family" --launch-type FARGATE \
  --network-configuration "awsvpcConfiguration={subnets=[${subnets}],securityGroups=[${sg}],assignPublicIp=ENABLED}" \
  --started-by "github-${GITHUB_RUN_ID:-local}" --query 'tasks[0].taskArn' --output text)
task_id="${task_arn##*/}"
echo "Started ${job} task ${task_id}"

# `aws ecs wait tasks-stopped` gives up after 10 minutes; training can take longer.
for _ in $(seq 1 120); do
  status=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].lastStatus' --output text)
  [ "$status" = "STOPPED" ] && break
  sleep 15
done

aws logs get-log-events --log-group-name "/ecs/churn-${env}/jobs" \
  --log-stream-name "${job}/${job}/${task_id}" --query 'events[].message' --output text | tr '\t' '\n' || true

code=$(aws ecs describe-tasks --cluster "$cluster" --tasks "$task_arn" --query 'tasks[0].containers[0].exitCode' --output text)
echo "${job} exited with ${code}"
[ "$code" = "0" ]
