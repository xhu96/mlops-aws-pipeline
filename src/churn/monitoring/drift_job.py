"""Scheduled drift check.

Reads captured predictions from S3 (or simulates live traffic), compares them
with the training profile shipped in the model bundle, publishes PSI per feature
to CloudWatch and prints a report. A CloudWatch alarm on `MaxPSI` pages the
on-call engineer; see docs/runbook.md.

    python -m churn.monitoring.drift_job --bucket my-capture-bucket --days 1
    python -m churn.monitoring.drift_job --simulate 0.8      # local demo, no AWS
"""

from __future__ import annotations

import argparse
import io
import json
import os
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pandas as pd

from churn import bundle, data
from churn.config import FEATURES
from churn.monitoring.profile import drift_report

NAMESPACE = "ChurnModel"
DRIFT_THRESHOLD = 0.2


def load_capture(bucket: str, prefix: str, days: int, s3=None) -> pd.DataFrame:
    import boto3

    s3 = s3 or boto3.client("s3")
    frames = []
    today = datetime.now(UTC).date()
    for offset in range(days):
        day = today - timedelta(days=offset)
        pages = s3.get_paginator("list_objects_v2").paginate(
            Bucket=bucket, Prefix=f"{prefix.rstrip('/')}/dt={day:%Y-%m-%d}/"
        )
        for page in pages:
            for obj in page.get("Contents", []):
                body = s3.get_object(Bucket=bucket, Key=obj["Key"])["Body"].read()
                frames.append(pd.read_json(io.BytesIO(body), lines=True))
    if not frames:
        return pd.DataFrame(columns=FEATURES)
    return pd.concat(frames, ignore_index=True)


def publish(report: dict[str, float], model_version: str, cloudwatch=None) -> None:
    import boto3

    cloudwatch = cloudwatch or boto3.client("cloudwatch")
    dims = [{"Name": "ModelVersion", "Value": model_version}]
    metric_data = [
        {
            "MetricName": "FeaturePSI",
            "Dimensions": dims + [{"Name": "Feature", "Value": feature}],
            "Value": value,
        }
        for feature, value in report.items()
    ]
    metric_data.append({"MetricName": "MaxPSI", "Value": max(report.values())})
    cloudwatch.put_metric_data(Namespace=NAMESPACE, MetricData=metric_data)


def run(
    model_dir: Path,
    live: pd.DataFrame,
    publish_metrics: bool,
    min_rows: int = 200,
) -> dict:
    profile = json.loads((model_dir / "profile.json").read_text())
    metadata = json.loads((model_dir / "metadata.json").read_text())
    if len(live) < min_rows:
        return {"status": "skipped", "reason": f"only {len(live)} rows, need {min_rows}"}

    report = drift_report(profile, live)
    max_psi = max(report.values())
    drifted = sorted(f for f, v in report.items() if v > DRIFT_THRESHOLD)
    if publish_metrics:
        publish(report, metadata["version"])
    result = {
        "status": "drift" if drifted else "ok",
        "model_version": metadata["version"],
        "rows": len(live),
        "max_psi": round(max_psi, 4),
        "drifted_features": drifted,
        "psi": {k: round(v, 4) for k, v in sorted(report.items(), key=lambda kv: -kv[1])},
    }
    _summary(result)
    return result


def _summary(result: dict) -> None:
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if not path:
        return
    lines = [
        f"### Drift check: {result['status'].upper()} (max PSI {result['max_psi']})",
        "",
        "| feature | PSI |",
        "|---|---|",
    ]
    lines += [f"| {f} | {v} |" for f, v in result["psi"].items()]
    with open(path, "a", encoding="utf-8") as fh:
        fh.write("\n".join(lines) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="churn.monitoring.drift_job")
    parser.add_argument(
        "--model-dir", type=Path, default=Path(os.environ.get("MODEL_DIR", "model"))
    )
    parser.add_argument("--bucket", default=os.environ.get("CAPTURE_BUCKET"))
    parser.add_argument("--prefix", default=os.environ.get("CAPTURE_PREFIX", "capture"))
    parser.add_argument("--days", type=int, default=1)
    parser.add_argument(
        "--bundle-uri",
        default=os.environ.get("BUNDLE_URI"),
        help="fetch the champion bundle from S3 into --model-dir first",
    )
    parser.add_argument("--simulate", type=float, default=None, help="drift level 0..1, no AWS")
    parser.add_argument("--fail-on-drift", action="store_true")
    args = parser.parse_args(argv)

    if args.bundle_uri:
        bundle.download_champion(args.bundle_uri, args.model_dir)

    if args.simulate is not None:
        live = data.generate(n=2000, seed=7, drift=args.simulate)
        result = run(args.model_dir, live, publish_metrics=False)
    else:
        if not args.bucket:
            parser.error("--bucket (or CAPTURE_BUCKET) is required unless --simulate is used")
        live = load_capture(args.bucket, args.prefix, args.days)
        result = run(args.model_dir, live, publish_metrics=True)

    print(json.dumps(result, indent=2))
    return 1 if args.fail_on_drift and result["status"] == "drift" else 0


if __name__ == "__main__":
    sys.exit(main())
