"""Synthetic but realistic telecom churn data.

The generator is deterministic for a given seed, so every training run in CI is
reproducible. `drift` shifts the input distribution the way a real market change
would (higher prices, more month-to-month contracts), which lets us exercise the
drift monitor and the incident drill end to end.
"""

from __future__ import annotations

import numpy as np
import pandas as pd

from churn.config import FEATURES, TARGET

CONTRACT_TYPES = ["month-to-month", "one-year", "two-year"]
INTERNET_SERVICES = ["fiber", "dsl", "none"]
PAYMENT_METHODS = ["card", "bank-transfer", "electronic-check"]


def generate(n: int = 20_000, seed: int = 42, drift: float = 0.0) -> pd.DataFrame:
    """Return `n` customers with features and a `churned` label.

    drift: 0.0 means training distribution; 1.0 means a strong shift.
    """
    if not 0.0 <= drift <= 1.0:
        raise ValueError("drift must be between 0 and 1")
    rng = np.random.default_rng(seed)

    contract_p = np.array([0.5, 0.3, 0.2]) * (1 - drift) + np.array([0.8, 0.15, 0.05]) * drift
    contract = rng.choice(CONTRACT_TYPES, size=n, p=contract_p)
    internet = rng.choice(INTERNET_SERVICES, size=n, p=[0.45, 0.4, 0.15])
    payment = rng.choice(PAYMENT_METHODS, size=n, p=[0.4, 0.3, 0.3])

    tenure = rng.gamma(shape=2.0, scale=14.0, size=n).clip(0, 72).round()
    base_charge = np.select([internet == "fiber", internet == "dsl"], [80.0, 55.0], default=25.0)
    monthly = (base_charge + rng.normal(0, 12, size=n) + 25 * drift).clip(15, 150).round(2)
    tickets = rng.poisson(lam=1.2 + 1.5 * drift, size=n)

    logit = (
        -1.2
        - 0.045 * tenure
        + 0.022 * (monthly - 60)
        + 0.35 * tickets
        + np.select(
            [contract == "month-to-month", contract == "one-year"], [1.4, 0.2], default=-1.0
        )
        + np.where(payment == "electronic-check", 0.5, 0.0)
        + np.where(internet == "fiber", 0.3, 0.0)
    )
    prob = 1 / (1 + np.exp(-1.6 * logit))
    churned = (rng.random(n) < prob).astype(int)

    df = pd.DataFrame(
        {
            "tenure_months": tenure.astype(int),
            "monthly_charges": monthly,
            "support_tickets": tickets.astype(int),
            "contract_type": contract,
            "internet_service": internet,
            "payment_method": payment,
            TARGET: churned,
        }
    )
    return df[FEATURES + [TARGET]]
