"""Command line entry points for the model lifecycle.

    python -m churn.pipeline train     # train, log to MLflow, register as @challenger
    python -m churn.pipeline gate      # quality gate: promote @challenger to @champion or fail
    python -m churn.pipeline rollback  # point @champion back at the previous champion
    python -m churn.pipeline export    # write the @champion bundle to MODEL_DIR (+ BUNDLE_URI)
    python -m churn.pipeline retrain   # train + gate + export: the scheduled job on AWS

Each command prints a JSON result and, when running in GitHub Actions, writes a
Markdown summary to the job page. A failed gate exits with code 1 so CI stops.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import joblib
import mlflow
import numpy as np
from mlflow.exceptions import MlflowException
from mlflow.models import infer_signature
from mlflow.tracking import MlflowClient

from churn import bundle, data
from churn.config import FEATURES, TARGET, Settings, get_settings
from churn.model import DEFAULT_PARAMS, build_pipeline, evaluate
from churn.monitoring.profile import build_profile

PREVIOUS_ALIAS = "previous-champion"


def _summary(markdown: str) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(markdown + "\n")


def _emit(result: dict) -> None:
    print(json.dumps(result, indent=2, default=str))


def _version_by_alias(client: MlflowClient, name: str, alias: str):
    try:
        return client.get_model_version_by_alias(name, alias)
    except MlflowException:
        return None


def train(
    settings: Settings,
    label_noise: float = 0.0,
    data_seed: int | None = None,
    drift: float = 0.0,
) -> dict:
    mlflow.set_tracking_uri(settings.mlflow_tracking_uri)
    mlflow.set_experiment(settings.experiment_name)

    seed = settings.seed if data_seed is None else data_seed
    # drift > 0 simulates retraining on recent data after the market has moved.
    df = data.generate(n=settings.n_samples, seed=seed, drift=drift)
    if label_noise:
        # Used by the demo to prove the gate blocks a bad model.
        rng = np.random.default_rng(seed)
        flip = rng.random(len(df)) < label_noise
        df.loc[flip, TARGET] = 1 - df.loc[flip, TARGET]

    # Every candidate is scored on the same frozen holdout set, so metrics from
    # different runs (and different training data) are directly comparable.
    holdout = data.generate(n=settings.eval_samples, seed=settings.eval_seed)
    X_train, y_train = df[FEATURES], df[TARGET]
    X_test, y_test = holdout[FEATURES], holdout[TARGET]

    with mlflow.start_run() as run:
        model = build_pipeline(seed=settings.seed).fit(X_train, y_train)
        metrics = evaluate(model, X_test, y_test)

        mlflow.log_params(
            {**DEFAULT_PARAMS, "data_seed": seed, "label_noise": label_noise, "data_drift": drift}
        )
        mlflow.log_params({"n_train": len(X_train), "n_test": len(X_test)})
        mlflow.log_metrics(metrics)
        mlflow.set_tags(
            {
                "git_sha": os.environ.get("GITHUB_SHA", "local"),
                "triggered_by": os.environ.get("GITHUB_ACTOR", os.environ.get("USER", "local")),
            }
        )
        mlflow.log_dict(build_profile(X_train), "profile.json")

        info = mlflow.sklearn.log_model(
            model,
            name="model",
            registered_model_name=settings.model_name,
            signature=infer_signature(X_test, model.predict_proba(X_test)[:, 1]),
            input_example=X_test.head(3),
            # MLflow serialises with skops and refuses unknown types on load; we
            # trust exactly the one type our own model needs, nothing broader.
            skops_trusted_types=[
                "sklearn.ensemble._hist_gradient_boosting.predictor.TreePredictor"
            ],
        )

    version = str(info.registered_model_version)
    client = MlflowClient()
    client.set_registered_model_alias(settings.model_name, settings.challenger_alias, version)

    result = {"run_id": run.info.run_id, "version": version, "metrics": metrics}
    _summary(
        f"### Training run\n\nRegistered `{settings.model_name}` v{version} as "
        f"`@{settings.challenger_alias}`\n\n"
        + "\n".join(f"- **{k}**: {v:.4f}" for k, v in metrics.items())
    )
    return result


def gate(settings: Settings) -> dict:
    mlflow.set_tracking_uri(settings.mlflow_tracking_uri)
    client = MlflowClient()
    challenger = _version_by_alias(client, settings.model_name, settings.challenger_alias)
    if challenger is None:
        raise SystemExit(f"No @{settings.challenger_alias} version to evaluate")
    champion = _version_by_alias(client, settings.model_name, settings.champion_alias)

    cand_auc = client.get_run(challenger.run_id).data.metrics["roc_auc"]
    champ_auc = client.get_run(champion.run_id).data.metrics["roc_auc"] if champion else None

    reasons = []
    if cand_auc < settings.min_roc_auc:
        reasons.append(f"roc_auc {cand_auc:.4f} below minimum {settings.min_roc_auc}")
    if champ_auc is not None and cand_auc < champ_auc - settings.max_regression:
        reasons.append(
            f"roc_auc {cand_auc:.4f} regresses vs champion {champ_auc:.4f} "
            f"(tolerance {settings.max_regression})"
        )
    passed = not reasons

    if passed and (champion is None or champion.version != challenger.version):
        if champion is not None:
            client.set_registered_model_alias(settings.model_name, PREVIOUS_ALIAS, champion.version)
        client.set_registered_model_alias(
            settings.model_name, settings.champion_alias, challenger.version
        )

    result = {
        "passed": passed,
        "challenger_version": str(challenger.version),
        "challenger_roc_auc": cand_auc,
        "champion_version": str(champion.version) if champion else None,
        "champion_roc_auc": champ_auc,
        "reasons": reasons,
    }
    verdict = "PASSED, promoted to @champion" if passed else "FAILED"
    _summary(
        f"### Quality gate: {verdict}\n\n"
        f"| | version | roc_auc |\n|---|---|---|\n"
        f"| challenger | {challenger.version} | {cand_auc:.4f} |\n"
        f"| champion | {champion.version if champion else '-'} | "
        f"{f'{champ_auc:.4f}' if champ_auc is not None else '-'} |\n\n"
        + "\n".join(f"- {r}" for r in reasons)
    )
    return result


def rollback(settings: Settings) -> dict:
    mlflow.set_tracking_uri(settings.mlflow_tracking_uri)
    client = MlflowClient()
    previous = _version_by_alias(client, settings.model_name, PREVIOUS_ALIAS)
    current = _version_by_alias(client, settings.model_name, settings.champion_alias)
    if previous is None:
        raise SystemExit("No previous champion to roll back to")
    client.set_registered_model_alias(
        settings.model_name, settings.champion_alias, previous.version
    )
    if current is not None:
        client.set_registered_model_alias(settings.model_name, PREVIOUS_ALIAS, current.version)
    _summary(f"### Rollback\n\n`@champion` moved from v{current.version} to v{previous.version}")
    return {
        "from_version": str(current.version) if current else None,
        "to_version": str(previous.version),
    }


def export(settings: Settings) -> dict:
    """Write a self-contained bundle that the API loads without talking to MLflow."""
    mlflow.set_tracking_uri(settings.mlflow_tracking_uri)
    client = MlflowClient()
    champion = _version_by_alias(client, settings.model_name, settings.champion_alias)
    if champion is None:
        raise SystemExit(f"No @{settings.champion_alias} version to export")

    model = mlflow.sklearn.load_model(f"models:/{settings.model_name}@{settings.champion_alias}")
    run = client.get_run(champion.run_id)
    with tempfile.TemporaryDirectory() as tmp:
        profile_path = mlflow.artifacts.download_artifacts(
            run_id=champion.run_id, artifact_path="profile.json", dst_path=tmp
        )
        profile = json.loads(Path(profile_path).read_text())

    out = settings.model_dir
    out.mkdir(parents=True, exist_ok=True)
    joblib.dump(model, out / "model.joblib")
    (out / "profile.json").write_text(json.dumps(profile))
    metadata = {
        "model_name": settings.model_name,
        "version": str(champion.version),
        "run_id": champion.run_id,
        "git_sha": run.data.tags.get("git_sha"),
        "metrics": run.data.metrics,
        "features": FEATURES,
        "exported_at": datetime.now(UTC).isoformat(),
    }
    (out / "metadata.json").write_text(json.dumps(metadata, indent=2))
    if settings.bundle_uri:
        metadata["bundle_uri"] = bundle.upload(out, settings.bundle_uri, metadata["version"])
    _summary(f"### Exported `{settings.model_name}` v{champion.version} to `{out}`")
    return metadata


def retrain(settings: Settings) -> dict:
    """train -> gate -> export in one process: what the scheduled ECS task runs."""
    trained = train(settings)
    decision = gate(settings)
    result = {"trained": trained, "gate": decision, "passed": decision["passed"]}
    if decision["passed"]:
        result["exported"] = export(settings)
    return result


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="churn.pipeline")
    sub = parser.add_subparsers(dest="command", required=True)
    p_train = sub.add_parser("train")
    p_train.add_argument("--label-noise", type=float, default=0.0)
    p_train.add_argument("--data-seed", type=int, default=None)
    p_train.add_argument("--drift", type=float, default=0.0)
    sub.add_parser("gate")
    sub.add_parser("rollback")
    sub.add_parser("export")
    sub.add_parser("retrain")
    args = parser.parse_args(argv)

    settings = get_settings()
    if args.command == "train":
        result = train(
            settings, label_noise=args.label_noise, data_seed=args.data_seed, drift=args.drift
        )
    elif args.command == "gate":
        result = gate(settings)
    elif args.command == "rollback":
        result = rollback(settings)
    elif args.command == "export":
        result = export(settings)
    else:
        result = retrain(settings)
    _emit(result)
    return 0 if result.get("passed", True) else 1


if __name__ == "__main__":
    sys.exit(main())
