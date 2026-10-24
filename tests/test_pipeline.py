"""End-to-end lifecycle against a throwaway MLflow registry."""

import json

import pytest

from churn import pipeline


@pytest.fixture
def mlflow_env(tmp_path, monkeypatch):
    monkeypatch.setenv("MLFLOW_TRACKING_URI", f"sqlite:///{tmp_path}/mlflow.db")
    monkeypatch.setenv("MODEL_DIR", str(tmp_path / "bundle"))
    monkeypatch.setenv("N_SAMPLES", "3000")
    monkeypatch.chdir(tmp_path)
    return tmp_path


def run(capsys, *args):
    code = pipeline.main(list(args))
    return code, json.loads(capsys.readouterr().out)


def test_full_lifecycle(mlflow_env, capsys):
    summary = mlflow_env / "summary.md"

    code, trained = run(capsys, "train")
    assert code == 0 and trained["version"] == "1"
    assert trained["metrics"]["roc_auc"] > 0.75

    # First model: no champion yet, so it only has to clear the absolute bar.
    code, gate = run(capsys, "gate")
    assert code == 0 and gate["passed"] and gate["champion_version"] is None

    # A model trained on corrupted labels must be blocked.
    run(capsys, "train", "--label-noise", "0.4")
    code, gate = run(capsys, "gate")
    assert code == 1 and not gate["passed"]
    assert gate["champion_version"] == "1"

    # A healthy retrain is promoted; v1 becomes the rollback target.
    run(capsys, "train", "--data-seed", "11")
    code, gate = run(capsys, "gate")
    assert code == 0 and gate["passed"] and gate["challenger_version"] == "3"

    code, rolled = run(capsys, "rollback")
    assert rolled == {"from_version": "3", "to_version": "1"}

    code, meta = run(capsys, "export")
    assert meta["version"] == "1"
    bundle = mlflow_env / "bundle"
    assert {p.name for p in bundle.iterdir()} == {"model.joblib", "metadata.json", "profile.json"}
    assert not summary.exists()


def test_gate_without_challenger(mlflow_env):
    with pytest.raises(SystemExit):
        pipeline.main(["gate"])


def test_summary_written_in_ci(mlflow_env, capsys, monkeypatch):
    summary = mlflow_env / "summary.md"
    monkeypatch.setenv("GITHUB_STEP_SUMMARY", str(summary))
    run(capsys, "train")
    run(capsys, "gate")
    text = summary.read_text()
    assert "Training run" in text and "Quality gate: PASSED" in text


def test_retrain_publishes_bundle(mlflow_env, capsys, monkeypatch):
    import boto3
    from moto import mock_aws

    with mock_aws():
        s3 = boto3.client("s3", region_name="eu-west-2")
        s3.create_bucket(
            Bucket="models", CreateBucketConfiguration={"LocationConstraint": "eu-west-2"}
        )
        monkeypatch.setenv("BUNDLE_URI", "s3://models/bundles")
        code, result = run(capsys, "retrain")
        assert code == 0 and result["passed"]
        assert result["exported"]["bundle_uri"] == "s3://models/bundles/v1/"
        keys = {o["Key"] for o in s3.list_objects_v2(Bucket="models")["Contents"]}
        assert "bundles/champion.json" in keys
