"""FastAPI service that serves the exported @champion model bundle."""

from __future__ import annotations

import json
import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

import joblib
import pandas as pd
from fastapi import FastAPI, HTTPException, Request, Response
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Gauge, Histogram, generate_latest
from pydantic import BaseModel, Field

from churn import bundle
from churn.config import FEATURES
from churn.serving.capture import S3Capture


class JsonFormatter(logging.Formatter):
    """One JSON object per line, which CloudWatch Logs Insights can query directly."""

    def format(self, record: logging.LogRecord) -> str:
        payload = {"level": record.levelname, "logger": record.name, "msg": record.getMessage()}
        for key in ("path", "status", "latency_ms", "model_version", "rows"):
            if hasattr(record, key):
                payload[key] = getattr(record, key)
        if record.exc_info:
            payload["exc"] = self.formatException(record.exc_info)
        return json.dumps(payload)


handler = logging.StreamHandler()
handler.setFormatter(JsonFormatter())
logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), handlers=[handler], force=True)
log = logging.getLogger("churn.api")

REQUESTS = Counter("http_requests_total", "HTTP requests", ["path", "status"])
LATENCY = Histogram("http_request_duration_seconds", "Request latency", ["path"])
PREDICTIONS = Histogram(
    "churn_prediction_score", "Predicted churn probability", buckets=[i / 10 for i in range(11)]
)
MODEL_INFO = Gauge("churn_model_info", "Loaded model version", ["version"])


class Customer(BaseModel):
    tenure_months: int = Field(ge=0, le=120)
    monthly_charges: float = Field(gt=0, le=500)
    support_tickets: int = Field(ge=0, le=100)
    contract_type: Literal["month-to-month", "one-year", "two-year"]
    internet_service: Literal["fiber", "dsl", "none"]
    payment_method: Literal["card", "bank-transfer", "electronic-check"]


class PredictRequest(BaseModel):
    customers: list[Customer] = Field(min_length=1, max_length=1000)


class Prediction(BaseModel):
    churn_probability: float
    will_churn: bool


class PredictResponse(BaseModel):
    model_version: str
    predictions: list[Prediction]


def load_bundle(model_dir: Path) -> tuple[object, dict]:
    model = joblib.load(model_dir / "model.joblib")
    metadata = json.loads((model_dir / "metadata.json").read_text())
    return model, metadata


@asynccontextmanager
async def lifespan(app: FastAPI):
    model_dir = Path(os.environ.get("MODEL_DIR", "model"))
    bundle_uri, version = os.environ.get("BUNDLE_URI"), os.environ.get("MODEL_VERSION")
    if bundle_uri and version:
        # On AWS the task definition pins MODEL_VERSION, so every revision maps to
        # exactly one code + model pair and an ECS rollback restores both.
        bundle.download(bundle_uri, version, model_dir)
    app.state.model, app.state.metadata = load_bundle(model_dir)
    app.state.threshold = float(os.environ.get("DECISION_THRESHOLD", "0.5"))
    MODEL_INFO.labels(version=app.state.metadata["version"]).set(1)

    bucket = os.environ.get("CAPTURE_BUCKET")
    app.state.capture = (
        S3Capture(
            bucket,
            prefix=os.environ.get("CAPTURE_PREFIX", "capture"),
            batch_size=int(os.environ.get("CAPTURE_BATCH_SIZE", "100")),
        )
        if bucket
        else None
    )
    log.info("model loaded", extra={"model_version": app.state.metadata["version"]})
    yield
    if app.state.capture:
        app.state.capture.flush()


app = FastAPI(title="Churn prediction API", version="0.1.0", lifespan=lifespan)


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    response = await call_next(request)
    elapsed = time.perf_counter() - start
    path = request.url.path
    REQUESTS.labels(path=path, status=response.status_code).inc()
    LATENCY.labels(path=path).observe(elapsed)
    if path not in ("/health", "/metrics"):
        log.info(
            "request",
            extra={
                "path": path,
                "status": response.status_code,
                "latency_ms": round(elapsed * 1000, 2),
            },
        )
    return response


@app.get("/health")
def health() -> dict:
    """Liveness and readiness: the model is loaded at startup, so up means ready."""
    return {"status": "ok", "model_version": app.state.metadata["version"]}


@app.get("/model")
def model_info() -> dict:
    return app.state.metadata


@app.post("/predict", response_model=PredictResponse)
def predict(req: PredictRequest) -> PredictResponse:
    rows = [c.model_dump() for c in req.customers]
    try:
        scores = app.state.model.predict_proba(pd.DataFrame(rows)[FEATURES])[:, 1].tolist()
    except Exception as exc:
        log.exception("prediction failed")
        raise HTTPException(status_code=500, detail="prediction failed") from exc

    for s in scores:
        PREDICTIONS.observe(s)
    version = app.state.metadata["version"]
    if app.state.capture:
        app.state.capture.record(rows, scores, version)

    return PredictResponse(
        model_version=version,
        predictions=[
            Prediction(churn_probability=round(s, 4), will_churn=s >= app.state.threshold)
            for s in scores
        ],
    )


@app.get("/metrics")
def metrics() -> Response:
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)
