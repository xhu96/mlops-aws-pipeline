# ADR 0005: Population Stability Index for drift detection

**Status:** accepted

## Context
We do not get the true churn outcome until weeks after a prediction, so live accuracy cannot be measured quickly. Changes in the input distribution are the earliest signal that the model may be wrong.

## Decision
At training time we store a profile of every feature (decile edges and proportions for numbers, category shares for categories) inside the bundle. A daily job compares captured live inputs with that profile using the Population Stability Index and publishes PSI per feature plus `MaxPSI` to CloudWatch. The alarm fires above 0.2, the usual "significant shift" threshold.

## Consequences
- Simple, explainable, under 100 lines of code with no extra dependency, and the job needs only the bundle and the captured data.
- PSI detects input drift, not concept drift (the relationship between inputs and churn changing). Catching that needs ground-truth labels, which is the next item on the roadmap.
- A minimum of 200 rows is required, so a quiet day does not raise a false alarm.
