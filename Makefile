SHELL := /bin/bash
.DEFAULT_GOAL := help
COMPOSE := docker compose
JOB := $(COMPOSE) run --rm trainer
BIN := $(if $(wildcard .venv/bin/python),.venv/bin/,)

help: ## Show available targets
	@grep -E '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

install: ## Create a virtualenv with all dev dependencies
	python3 -m venv .venv && .venv/bin/pip install -r requirements/dev.txt && .venv/bin/pip install --no-deps -e .

lint: ## Ruff lint + format check
	$(BIN)ruff check . && $(BIN)ruff format --check .

test: ## Unit and integration tests with coverage
	$(BIN)pytest

up: ## Start LocalStack, MLflow (http://localhost:5000) and the API (http://localhost:8000)
	$(COMPOSE) up -d --build --wait localstack mlflow

down: ## Stop everything and delete local state
	$(COMPOSE) --profile jobs down -v

train: ## Train a model and register it as @challenger
	$(JOB) train

gate: ## Promote @challenger to @champion if it passes the quality gate
	$(JOB) gate

export: ## Export the @champion bundle to ./model
	$(JOB) export

serve: ## (Re)start the API with the exported bundle
	$(COMPOSE) up -d --build --force-recreate --wait api

traffic: ## Send normal traffic to the API
	$(BIN)python scripts/send_traffic.py --n 1000

drift-traffic: ## Send drifted traffic (simulates a market change)
	$(BIN)python scripts/send_traffic.py --n 1000 --drift 0.9

drift: ## Run the drift check on captured traffic
	$(COMPOSE) restart api >/dev/null
	$(COMPOSE) run --rm --entrypoint python trainer -m churn.monitoring.drift_job --bucket churn-capture

demo: up train gate export serve traffic drift-traffic drift ## Full lifecycle end to end
	@echo "Open MLflow at http://localhost:5000 and the API docs at http://localhost:8000/docs"

tf-check: ## Terraform fmt + validate for every environment
	terraform -chdir=infra/terraform fmt -check -recursive
	for env in dev prod; do terraform -chdir=infra/terraform/envs/$$env init -backend=false -input=false >/dev/null && terraform -chdir=infra/terraform/envs/$$env validate; done

.PHONY: help install lint test up down train gate export serve traffic drift-traffic drift demo tf-check
