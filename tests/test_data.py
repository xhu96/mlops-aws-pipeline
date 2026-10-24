import pytest

from churn import data
from churn.config import FEATURES, TARGET


def test_generate_is_deterministic():
    a = data.generate(n=500, seed=3)
    b = data.generate(n=500, seed=3)
    assert a.equals(b)


def test_schema_and_ranges():
    df = data.generate(n=1000, seed=0)
    assert list(df.columns) == FEATURES + [TARGET]
    assert df["tenure_months"].between(0, 72).all()
    assert df["monthly_charges"].between(15, 150).all()
    assert set(df[TARGET].unique()) <= {0, 1}
    assert 0.1 < df[TARGET].mean() < 0.6


def test_drift_shifts_distribution():
    base = data.generate(n=5000, seed=0)
    drifted = data.generate(n=5000, seed=0, drift=1.0)
    assert drifted["monthly_charges"].mean() > base["monthly_charges"].mean() + 15
    assert (drifted["contract_type"] == "month-to-month").mean() > 0.7


def test_drift_out_of_range():
    with pytest.raises(ValueError):
        data.generate(n=10, drift=1.5)
