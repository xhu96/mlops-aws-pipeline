import boto3
import pytest
from fastapi.testclient import TestClient
from moto import mock_aws

CUSTOMER = {
    "tenure_months": 2,
    "monthly_charges": 95.5,
    "support_tickets": 4,
    "contract_type": "month-to-month",
    "internet_service": "fiber",
    "payment_method": "electronic-check",
}
LOYAL = {
    **CUSTOMER,
    "tenure_months": 60,
    "monthly_charges": 30,
    "support_tickets": 0,
    "contract_type": "two-year",
    "internet_service": "none",
    "payment_method": "card",
}


@pytest.fixture
def client(bundle_dir, monkeypatch):
    monkeypatch.setenv("MODEL_DIR", str(bundle_dir))
    monkeypatch.delenv("CAPTURE_BUCKET", raising=False)
    from churn.serving.app import app

    with TestClient(app) as c:
        yield c


def test_health(client):
    assert client.get("/health").json() == {"status": "ok", "model_version": "7"}


def test_model_info(client):
    assert client.get("/model").json()["version"] == "7"


def test_predict_ranks_risky_customer_higher(client):
    res = client.post("/predict", json={"customers": [CUSTOMER, LOYAL]})
    assert res.status_code == 200
    body = res.json()
    assert body["model_version"] == "7"
    risky, loyal = (p["churn_probability"] for p in body["predictions"])
    assert risky > loyal


@pytest.mark.parametrize(
    "payload",
    [
        {"customers": []},
        {"customers": [{**CUSTOMER, "contract_type": "weekly"}]},
        {"customers": [{**CUSTOMER, "tenure_months": -1}]},
        {"customers": [{k: v for k, v in CUSTOMER.items() if k != "monthly_charges"}]},
    ],
)
def test_invalid_input_rejected(client, payload):
    assert client.post("/predict", json=payload).status_code == 422


def test_metrics_exposed(client):
    client.post("/predict", json={"customers": [CUSTOMER]})
    text = client.get("/metrics").text
    assert "churn_prediction_score_count" in text
    assert 'churn_model_info{version="7"} 1.0' in text


@mock_aws
def test_capture_writes_to_s3(bundle_dir, monkeypatch):
    s3 = boto3.client("s3", region_name="eu-west-2")
    s3.create_bucket(Bucket="cap", CreateBucketConfiguration={"LocationConstraint": "eu-west-2"})
    monkeypatch.setenv("MODEL_DIR", str(bundle_dir))
    monkeypatch.setenv("CAPTURE_BUCKET", "cap")
    monkeypatch.setenv("CAPTURE_BATCH_SIZE", "2")
    from churn.serving.app import app

    with TestClient(app) as c:
        c.post("/predict", json={"customers": [CUSTOMER, LOYAL, CUSTOMER]})
    # Two rows flushed by batch size, one more on shutdown.
    keys = [o["Key"] for o in s3.list_objects_v2(Bucket="cap")["Contents"]]
    assert len(keys) == 1 or len(keys) == 2
    assert all(k.startswith("capture/dt=") for k in keys)


@mock_aws
def test_downloads_pinned_bundle_version(bundle_dir, tmp_path, monkeypatch):
    from churn import bundle

    s3 = boto3.client("s3", region_name="eu-west-2")
    s3.create_bucket(
        Bucket="models-test", CreateBucketConfiguration={"LocationConstraint": "eu-west-2"}
    )
    bundle.upload(bundle_dir, "s3://models-test/bundles", "7", s3=s3)
    monkeypatch.setenv("BUNDLE_URI", "s3://models-test/bundles")
    monkeypatch.setenv("MODEL_VERSION", "7")
    monkeypatch.setenv("MODEL_DIR", str(tmp_path / "pulled"))
    monkeypatch.delenv("CAPTURE_BUCKET", raising=False)
    from churn.serving.app import app

    with TestClient(app) as c:
        assert c.get("/health").json()["model_version"] == "7"
    assert (tmp_path / "pulled" / "model.joblib").exists()
