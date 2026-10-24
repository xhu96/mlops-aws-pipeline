from churn import data
from churn.monitoring.profile import build_profile, drift_report, psi


def test_psi_identical_is_zero():
    assert psi([0.5, 0.5], [0.5, 0.5]) == 0


def test_no_drift_on_same_distribution():
    profile = build_profile(data.generate(n=5000, seed=0))
    report = drift_report(profile, data.generate(n=5000, seed=99))
    assert max(report.values()) < 0.1


def test_drift_detected():
    profile = build_profile(data.generate(n=5000, seed=0))
    report = drift_report(profile, data.generate(n=5000, seed=99, drift=1.0))
    assert report["monthly_charges"] > 0.2
    assert report["contract_type"] > 0.2


def test_unseen_category_counts_as_drift():
    profile = build_profile(data.generate(n=2000, seed=0))
    live = data.generate(n=2000, seed=1)
    live["payment_method"] = "crypto"
    assert drift_report(profile, live)["payment_method"] > 1
