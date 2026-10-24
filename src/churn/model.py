"""Model definition and evaluation, independent of MLflow and of serving."""

from __future__ import annotations

from typing import Any

import numpy as np
import pandas as pd
from sklearn.compose import ColumnTransformer
from sklearn.ensemble import HistGradientBoostingClassifier
from sklearn.metrics import f1_score, precision_score, recall_score, roc_auc_score
from sklearn.pipeline import Pipeline
from sklearn.preprocessing import OneHotEncoder, StandardScaler

from churn.config import CATEGORICAL_FEATURES, NUMERIC_FEATURES

DEFAULT_PARAMS: dict[str, Any] = {
    "learning_rate": 0.08,
    "max_iter": 250,
    "max_leaf_nodes": 31,
    "l2_regularization": 0.1,
}


def build_pipeline(params: dict[str, Any] | None = None, seed: int = 42) -> Pipeline:
    params = {**DEFAULT_PARAMS, **(params or {})}
    preprocess = ColumnTransformer(
        [
            ("num", StandardScaler(), NUMERIC_FEATURES),
            (
                "cat",
                OneHotEncoder(handle_unknown="ignore", sparse_output=False),
                CATEGORICAL_FEATURES,
            ),
        ]
    )
    clf = HistGradientBoostingClassifier(random_state=seed, **params)
    return Pipeline([("preprocess", preprocess), ("clf", clf)])


def evaluate(model: Pipeline, X: pd.DataFrame, y: pd.Series, threshold: float = 0.5) -> dict:
    proba = model.predict_proba(X)[:, 1]
    pred = (proba >= threshold).astype(int)
    return {
        "roc_auc": float(roc_auc_score(y, proba)),
        "f1": float(f1_score(y, pred)),
        "precision": float(precision_score(y, pred, zero_division=0)),
        "recall": float(recall_score(y, pred)),
        "positive_rate": float(np.mean(pred)),
    }
