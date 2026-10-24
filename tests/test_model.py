from sklearn.model_selection import train_test_split

from churn.config import FEATURES, TARGET
from churn.model import build_pipeline, evaluate


def test_model_learns_signal(dataset):
    X_tr, X_te, y_tr, y_te = train_test_split(
        dataset[FEATURES], dataset[TARGET], test_size=0.25, random_state=0
    )
    metrics = evaluate(build_pipeline().fit(X_tr, y_tr), X_te, y_te)
    assert metrics["roc_auc"] > 0.75
    assert set(metrics) == {"roc_auc", "f1", "precision", "recall", "positive_rate"}


def test_unknown_category_does_not_crash(dataset):
    model = build_pipeline().fit(dataset[FEATURES], dataset[TARGET])
    row = dataset[FEATURES].head(1).copy()
    row["payment_method"] = "crypto"
    assert 0 <= model.predict_proba(row)[0, 1] <= 1
