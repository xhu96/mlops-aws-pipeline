import json

import boto3
from moto import mock_aws

from churn import data
from churn.monitoring import drift_job


def test_simulated_no_drift(bundle_dir):
    assert (
        drift_job.main(["--model-dir", str(bundle_dir), "--simulate", "0", "--fail-on-drift"]) == 0
    )


def test_simulated_drift_fails(bundle_dir, capsys):
    code = drift_job.main(["--model-dir", str(bundle_dir), "--simulate", "1", "--fail-on-drift"])
    out = json.loads(capsys.readouterr().out)
    assert code == 1
    assert out["status"] == "drift"
    assert "monthly_charges" in out["drifted_features"]


def test_skips_with_too_little_traffic(bundle_dir):
    result = drift_job.run(bundle_dir, data.generate(n=10), publish_metrics=False)
    assert result["status"] == "skipped"


@mock_aws
def test_reads_capture_and_publishes_metrics(bundle_dir):
    s3 = boto3.client("s3", region_name="eu-west-2")
    s3.create_bucket(Bucket="cap", CreateBucketConfiguration={"LocationConstraint": "eu-west-2"})
    live = data.generate(n=500, seed=5, drift=1.0)
    from datetime import UTC, datetime

    key = f"capture/dt={datetime.now(UTC):%Y-%m-%d}/a.jsonl"
    s3.put_object(Bucket="cap", Key=key, Body=live.to_json(orient="records", lines=True).encode())

    frame = drift_job.load_capture("cap", "capture", days=1, s3=s3)
    assert len(frame) == 500
    result = drift_job.run(bundle_dir, frame, publish_metrics=True)
    assert result["status"] == "drift"

    cw = boto3.client("cloudwatch", region_name="eu-west-2")
    names = {m["MetricName"] for m in cw.list_metrics(Namespace="ChurnModel")["Metrics"]}
    assert names == {"FeaturePSI", "MaxPSI"}
