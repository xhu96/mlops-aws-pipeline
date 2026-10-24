"""Data profiles and Population Stability Index (PSI) for drift detection.

A profile is a small JSON-serialisable summary of the training data. It ships
inside the model bundle, so the drift job only needs the bundle plus a sample
of live traffic: no access to the original training set.

PSI rule of thumb: < 0.1 stable, 0.1-0.2 moderate shift, > 0.2 significant.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from churn.config import CATEGORICAL_FEATURES, NUMERIC_FEATURES

N_BINS = 10
EPS = 1e-4


def build_profile(df: pd.DataFrame) -> dict:
    profile: dict = {"numeric": {}, "categorical": {}, "n_rows": int(len(df))}
    for col in NUMERIC_FEATURES:
        edges = np.unique(np.quantile(df[col], np.linspace(0, 1, N_BINS + 1)))
        # Open-ended outer bins so live values outside the training range still count.
        inner = edges[1:-1].tolist()
        props = _numeric_props(df[col].to_numpy(), inner)
        profile["numeric"][col] = {"edges": inner, "props": props}
    for col in CATEGORICAL_FEATURES:
        props = df[col].value_counts(normalize=True).sort_index()
        profile["categorical"][col] = {str(k): float(v) for k, v in props.items()}
    return profile


def _numeric_props(values: np.ndarray, inner_edges: list[float]) -> list[float]:
    idx = np.searchsorted(np.asarray(inner_edges), values, side="right")
    counts = np.bincount(idx, minlength=len(inner_edges) + 1)
    return (counts / max(len(values), 1)).tolist()


def psi(expected: list[float], actual: list[float]) -> float:
    e = np.clip(np.asarray(expected, dtype=float), EPS, None)
    a = np.clip(np.asarray(actual, dtype=float), EPS, None)
    return float(np.sum((a - e) * np.log(a / e)))


def drift_report(profile: dict, live: pd.DataFrame) -> dict[str, float]:
    """PSI per feature between the reference profile and a live sample."""
    report: dict[str, float] = {}
    for col, ref in profile["numeric"].items():
        actual = _numeric_props(live[col].to_numpy(dtype=float), ref["edges"])
        report[col] = psi(ref["props"], actual)
    for col, ref in profile["categorical"].items():
        live_props = live[col].astype(str).value_counts(normalize=True)
        cats = sorted(set(ref) | set(live_props.index))
        report[col] = psi(
            [ref.get(c, 0.0) for c in cats], [float(live_props.get(c, 0.0)) for c in cats]
        )
    return report
