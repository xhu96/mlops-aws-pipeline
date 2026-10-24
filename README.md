# Churn MLOps on AWS

[![CI](https://github.com/xhu96/mlops-aws-pipeline/actions/workflows/ci.yml/badge.svg)](https://github.com/xhu96/mlops-aws-pipeline/actions/workflows/ci.yml)
![Python 3.12](https://img.shields.io/badge/python-3.12-blue)
![Terraform](https://img.shields.io/badge/IaC-Terraform-7B42BC)
![AWS](https://img.shields.io/badge/cloud-AWS-FF9900)

An end-to-end pipeline that takes a machine learning model from training to production on AWS and keeps it healthy once it is there: **repeatable deployments, no manual steps, and a model that cannot reach production unless it beats the one already serving.**

The model itself (customer churn, gradient boosting) is deliberately simple. The point of the project is everything around it.

```
 git push ─► CI: lint · 31 tests · image build · CVE scan · smoke test · terraform test
                │
                ▼
         Deploy (GitHub Actions, OIDC, no AWS keys)
                │  build images once, tag = git SHA
                ▼
   ┌──────────── dev (ML workspace) ────────────┐        ┌──────── prod ────────┐
   │ retrain task ─► MLflow registry            │        │                      │
   │      train ─► quality gate ─► @champion    │ approve│  same images         │
   │                       └─► bundle v7 on S3 ─┼───────►│  same bundle v7      │
   │ API on ECS Fargate (serves v7) + smoke test│        │  API on ECS Fargate  │
   └────────────────────────────────────────────┘        └──────────────────────┘
        live inputs ─► S3 capture ─► daily drift job (PSI) ─► CloudWatch alarm ─► email
```

## What it shows

| Area | How |
|---|---|
| **CI/CD with GitHub Actions** | [`ci.yml`](.github/workflows/ci.yml) on every PR, [`deploy.yml`](.github/workflows/deploy.yml) dev → manual approval → prod, [`retrain.yml`](.github/workflows/retrain.yml) weekly |
| **AWS infrastructure as code** | Terraform: VPC, ECS Fargate, ALB, RDS, S3, ECR, IAM, EventBridge Scheduler, CloudWatch ([`infra/terraform`](infra/terraform)) |
| **Infrastructure tests** | `terraform test` with a mocked AWS provider checks the safety rules (private DB, rollback on failed deploys, locked-down buckets) without an AWS account |
| **Model versioning and experiment tracking** | MLflow tracking server + model registry, aliases `@challenger` / `@champion` / `@previous-champion` |
| **Safe model releases** | Quality gate on a frozen holdout set: absolute minimum *and* no regression vs the current champion |
| **Packaging and deployment of models** | Self-contained bundle (model + metadata + training profile) on S3; ECS task definition pins the bundle version, so one revision = one code version + one model version |
| **Monitoring** | Structured JSON logs, Prometheus `/metrics`, CloudWatch alarms (5xx, p95 latency, unhealthy targets, data drift, failed ML jobs) and a dashboard |
| **Data drift** | Prediction capture to S3, daily Population Stability Index per feature, alarm above 0.2 |
| **Security** | OIDC instead of access keys, least-privilege task roles, DB password generated in Secrets Manager, private MLflow, TLS-only encrypted buckets, non-root read-only containers, Trivy scan, Dependabot |
| **Consistent environments** | One Docker Compose stack with LocalStack reproduces the AWS setup on a laptop; dev and prod come from the same Terraform module |
| **Operations** | [Runbook](docs/runbook.md) linked from every alarm, [incident drill](scripts/incident_drill.sh) with a [post-mortem](docs/postmortems/2026-10-pricing-drift.md) |

## Run it locally in 5 minutes

Needs Docker and Python 3.12. No AWS account: LocalStack stands in for S3 and CloudWatch.

```bash
make install        # virtualenv with pinned dependencies
make test           # 31 tests, ~96% coverage
make demo           # LocalStack + MLflow, train, gate, export, serve, traffic, drift check
```

Then open:

- MLflow UI: http://localhost:5000 (runs, metrics, registered versions and aliases)
- API docs: http://localhost:8000/docs

```bash
curl -s localhost:8000/predict -H 'Content-Type: application/json' -d '{
  "customers": [{"tenure_months": 2, "monthly_charges": 95, "support_tickets": 4,
                 "contract_type": "month-to-month", "internet_service": "fiber",
                 "payment_method": "electronic-check"}]}'
# {"model_version":"1","predictions":[{"churn_probability":0.99,"will_churn":true}]}
```

### The incident drill

```bash
./scripts/incident_drill.sh
```

Replays a realistic incident end to end: a price rise shifts the inputs, the drift check fires, a rushed retrain on bad labels is **blocked by the quality gate**, a proper retrain is promoted, the drift check goes green, and a rollback is rehearsed. The write-up is in [docs/postmortems](docs/postmortems/2026-10-pricing-drift.md).

## Model lifecycle

```bash
python -m churn.pipeline train      # train, log to MLflow, register as @challenger
python -m churn.pipeline gate       # promote to @champion, or exit 1 with the reasons
python -m churn.pipeline export     # write the @champion bundle (and publish it to S3)
python -m churn.pipeline retrain    # all three: what the ECS task runs
python -m churn.pipeline rollback   # @champion back to @previous-champion
```

The gate compares candidates on the **same frozen holdout set**, so metrics from different runs are comparable. A candidate must reach ROC AUC ≥ 0.75 and must not be more than 0.01 worse than the champion. In CI, results land in the job summary.

## Deploying to AWS

One-off setup (about 15 minutes):

```bash
# 1. state bucket
terraform -chdir=infra/terraform/bootstrap init && terraform -chdir=infra/terraform/bootstrap apply

# 2. ECR repositories + GitHub OIDC roles
terraform -chdir=infra/terraform/global init -backend-config="bucket=churn-tfstate-<account-id>"
terraform -chdir=infra/terraform/global apply
```

3. In the GitHub repo settings: add the variable `AWS_ACCOUNT_ID` (and optionally `ALERT_EMAIL`), and create the environments `dev` and `prod`, with a required reviewer on `prod`.
4. Push to `main`. The first deploy creates the dev stack, runs the first training job, deploys the model, smoke-tests it, and waits for approval before prod.

Until `AWS_ACCOUNT_ID` is set, every AWS job is skipped and CI stays green.

**Cost.** dev costs roughly £50-60/month while running (ALB, one small RDS, a few small Fargate tasks). No NAT gateways ([ADR 0003](docs/adr/0003-no-nat-gateway.md)). `terraform destroy` on `envs/dev` removes everything.

## Repository layout

```
src/churn/             model, training lifecycle, API, drift monitoring
tests/                 pytest (unit + integration with moto and a throwaway MLflow)
Dockerfile             three targets: api, trainer, mlflow
docker-compose.yml     local replica of AWS with LocalStack
infra/terraform/       bootstrap, global (ECR + OIDC), modules, envs/dev, envs/prod
.github/workflows/     ci, deploy, retrain
scripts/               traffic generator, incident drill, CI helpers
docs/                  architecture, ADRs, runbook, post-mortems
```

## Design decisions

- [ADR 0001: Serve an exported bundle, not the registry](docs/adr/0001-serve-exported-bundles.md)
- [ADR 0002: Train in dev, promote bundles to prod](docs/adr/0002-train-in-dev-promote-to-prod.md)
- [ADR 0003: No NAT gateway](docs/adr/0003-no-nat-gateway.md)
- [ADR 0004: GitHub OIDC instead of access keys](docs/adr/0004-github-oidc.md)
- [ADR 0005: PSI for drift detection](docs/adr/0005-psi-drift.md)

More detail in [docs/architecture.md](docs/architecture.md).

## What I would add next

- HTTPS with a real domain (the Terraform already supports an ACM certificate) and authentication on the API
- Canary deploys with CodeDeploy, shifting 10% of traffic before full rollout
- Ground-truth feedback loop: join captured predictions with real churn outcomes to track live accuracy, not only input drift
- Permission boundary on the deploy roles to tighten IAM further
