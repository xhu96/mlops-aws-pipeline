import json

import boto3
import pytest
from moto import mock_aws

from churn import bundle
from churn.monitoring import drift_job


@pytest.fixture
def s3():
    with mock_aws():
        client = boto3.client("s3", region_name="eu-west-2")
        client.create_bucket(
            Bucket="models", CreateBucketConfiguration={"LocationConstraint": "eu-west-2"}
        )
        yield client


def test_round_trip(s3, bundle_dir, tmp_path):
    uri = bundle.upload(bundle_dir, "s3://models/bundles", "7", s3=s3)
    assert uri == "s3://models/bundles/v7/"
    pointer = s3.get_object(Bucket="models", Key="bundles/champion.json")["Body"].read()
    assert json.loads(pointer) == {"version": "7"}

    assert bundle.champion_version("s3://models/bundles", s3=s3) == "7"
    assert bundle.main(["champion", "s3://models/bundles"]) == 0
    assert bundle.main(["download", "s3://models/bundles", str(tmp_path / "m")]) == 0
    assert sorted(p.name for p in (tmp_path / "m").iterdir()) == sorted(bundle.BUNDLE_FILES)


def test_drift_job_fetches_bundle(s3, bundle_dir, tmp_path):
    bundle.upload(bundle_dir, "s3://models/bundles", "7", s3=s3)
    args = ["--bundle-uri", "s3://models/bundles", "--model-dir", str(tmp_path), "--simulate", "0"]
    assert drift_job.main(args) == 0


def test_bad_uri():
    with pytest.raises(ValueError):
        bundle.download_champion("https://example.com/x", None)
