"""Prediction capture: batches live inputs and outputs to S3 as JSON Lines.

The drift job reads these files back and compares them with the training
profile. Capture is best effort: a failing upload is logged and never breaks a
prediction request.
"""

from __future__ import annotations

import json
import logging
import threading
import uuid
from datetime import UTC, datetime

log = logging.getLogger(__name__)


class S3Capture:
    def __init__(self, bucket: str, prefix: str, batch_size: int = 100, client=None):
        import boto3

        self.bucket = bucket
        self.prefix = prefix.rstrip("/")
        self.batch_size = batch_size
        self._client = client or boto3.client("s3")
        self._buffer: list[dict] = []
        self._lock = threading.Lock()

    def record(self, rows: list[dict], scores: list[float], model_version: str) -> None:
        ts = datetime.now(UTC).isoformat()
        with self._lock:
            for row, score in zip(rows, scores, strict=True):
                self._buffer.append(
                    {**row, "score": score, "model_version": model_version, "ts": ts}
                )
            if len(self._buffer) < self.batch_size:
                return
            batch, self._buffer = self._buffer, []
        self._upload(batch)

    def flush(self) -> None:
        with self._lock:
            batch, self._buffer = self._buffer, []
        if batch:
            self._upload(batch)

    def _upload(self, batch: list[dict]) -> None:
        now = datetime.now(UTC)
        key = f"{self.prefix}/dt={now:%Y-%m-%d}/{now:%H%M%S}-{uuid.uuid4().hex[:8]}.jsonl"
        body = "\n".join(json.dumps(r) for r in batch).encode()
        try:
            self._client.put_object(Bucket=self.bucket, Key=key, Body=body)
        except Exception:  # noqa: BLE001 - capture must never break serving
            log.exception("prediction capture upload failed", extra={"rows": len(batch)})
