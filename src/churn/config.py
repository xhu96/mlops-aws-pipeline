"""Central configuration, read from environment variables.

Every setting has a local-friendly default so `make train` works out of the box,
and every setting can be overridden in CI or on AWS without code changes.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path

NUMERIC_FEATURES = ["tenure_months", "monthly_charges", "support_tickets"]
CATEGORICAL_FEATURES = ["contract_type", "internet_service", "payment_method"]
FEATURES = NUMERIC_FEATURES + CATEGORICAL_FEATURES
TARGET = "churned"


def _env(name: str, default: str) -> str:
    return os.environ.get(name, default)


@dataclass(frozen=True)
class Settings:
    mlflow_tracking_uri: str = field(
        default_factory=lambda: _env("MLFLOW_TRACKING_URI", "sqlite:///mlruns.db")
    )
    experiment_name: str = field(default_factory=lambda: _env("MLFLOW_EXPERIMENT", "churn"))
    model_name: str = field(default_factory=lambda: _env("MODEL_NAME", "churn-classifier"))
    champion_alias: str = "champion"
    challenger_alias: str = "challenger"

    # Quality gate: a candidate must clear an absolute bar AND not regress
    # against the current champion by more than the tolerance.
    min_roc_auc: float = field(default_factory=lambda: float(_env("GATE_MIN_ROC_AUC", "0.75")))
    max_regression: float = field(
        default_factory=lambda: float(_env("GATE_MAX_REGRESSION", "0.01"))
    )

    seed: int = field(default_factory=lambda: int(_env("SEED", "42")))
    n_samples: int = field(default_factory=lambda: int(_env("N_SAMPLES", "20000")))
    eval_samples: int = field(default_factory=lambda: int(_env("EVAL_SAMPLES", "5000")))
    eval_seed: int = 2024

    model_dir: Path = field(default_factory=lambda: Path(_env("MODEL_DIR", "model")))
    # Optional s3://bucket/prefix where exported bundles are published.
    bundle_uri: str = field(default_factory=lambda: _env("BUNDLE_URI", ""))


def get_settings() -> Settings:
    return Settings()
