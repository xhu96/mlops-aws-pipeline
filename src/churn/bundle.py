"""Publish and fetch model bundles on S3.

Layout under the bundle URI (e.g. s3://churn-dev-models/bundles):

    v3/model.joblib, v3/metadata.json, v3/profile.json
    champion.json           -> {"version": "3"}

CI downloads the champion bundle to bake it into the API image, and the drift
job downloads it to get the training profile. Neither needs to reach MLflow.
"""

from __future__ import annotations

import json
from pathlib import Path
from urllib.parse import urlparse

BUNDLE_FILES = ("model.joblib", "metadata.json", "profile.json")


def _split(uri: str) -> tuple[str, str]:
    parsed = urlparse(uri)
    if parsed.scheme != "s3" or not parsed.netloc:
        raise ValueError(f"expected s3://bucket/prefix, got {uri!r}")
    return parsed.netloc, parsed.path.strip("/")


def _client(s3):
    if s3 is not None:
        return s3
    import boto3

    return boto3.client("s3")


def upload(model_dir: Path, uri: str, version: str, s3=None) -> str:
    s3 = _client(s3)
    bucket, prefix = _split(uri)
    for name in BUNDLE_FILES:
        s3.upload_file(str(model_dir / name), bucket, f"{prefix}/v{version}/{name}")
    s3.put_object(
        Bucket=bucket,
        Key=f"{prefix}/champion.json",
        Body=json.dumps({"version": version}).encode(),
        ContentType="application/json",
    )
    return f"s3://{bucket}/{prefix}/v{version}/"


def champion_version(uri: str, s3=None) -> str:
    s3 = _client(s3)
    bucket, prefix = _split(uri)
    pointer = json.loads(s3.get_object(Bucket=bucket, Key=f"{prefix}/champion.json")["Body"].read())
    return str(pointer["version"])


def download(uri: str, version: str, model_dir: Path, s3=None) -> str:
    s3 = _client(s3)
    bucket, prefix = _split(uri)
    model_dir.mkdir(parents=True, exist_ok=True)
    for name in BUNDLE_FILES:
        s3.download_file(bucket, f"{prefix}/v{version}/{name}", str(model_dir / name))
    return version


def download_champion(uri: str, model_dir: Path, s3=None) -> str:
    s3 = _client(s3)
    return download(uri, champion_version(uri, s3=s3), model_dir, s3=s3)


def main(argv: list[str] | None = None) -> int:
    """CLI used by CI:

    python -m churn.bundle champion s3://bucket/bundles          -> prints version
    python -m churn.bundle download s3://bucket/bundles model/   -> downloads champion
    """
    import argparse

    parser = argparse.ArgumentParser(prog="churn.bundle")
    parser.add_argument("action", choices=["champion", "download"])
    parser.add_argument("uri")
    parser.add_argument("model_dir", type=Path, nargs="?", default=Path("model"))
    args = parser.parse_args(argv)
    if args.action == "champion":
        print(champion_version(args.uri))
    else:
        print(download_champion(args.uri, args.model_dir))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
