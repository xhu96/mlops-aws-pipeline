import json

import joblib
import pytest
from sklearn.model_selection import train_test_split

from churn import data
from churn.config import FEATURES, TARGET
from churn.model import build_pipeline
from churn.monitoring.profile import build_profile


@pytest.fixture(scope="session")
def dataset():
    return data.generate(n=4000, seed=1)


@pytest.fixture(scope="session")
def bundle_dir(tmp_path_factory, dataset):
    """A model bundle in the same layout `pipeline export` writes, built without MLflow."""
    out = tmp_path_factory.mktemp("model")
    X_train, _, y_train, _ = train_test_split(
        dataset[FEATURES], dataset[TARGET], test_size=0.2, random_state=0
    )
    joblib.dump(build_pipeline().fit(X_train, y_train), out / "model.joblib")
    (out / "profile.json").write_text(json.dumps(build_profile(X_train)))
    (out / "metadata.json").write_text(json.dumps({"version": "7", "features": FEATURES}))
    return out


@pytest.fixture(autouse=True)
def aws_env(monkeypatch):
    for key, value in {
        "AWS_ACCESS_KEY_ID": "testing",
        "AWS_SECRET_ACCESS_KEY": "testing",
        "AWS_DEFAULT_REGION": "eu-west-2",
        "MLFLOW_DISABLE_TELEMETRY": "true",
        "MLFLOW_DISABLE_AGENT_HINT": "1",
    }.items():
        monkeypatch.setenv(key, value)
    monkeypatch.delenv("GITHUB_STEP_SUMMARY", raising=False)
