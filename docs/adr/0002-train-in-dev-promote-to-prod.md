# ADR 0002: Train in dev, promote bundles to prod

**Status:** accepted

## Context
Training separately in each environment would give dev and prod different model versions with different numbers, and a model would reach prod without ever having been served in dev.

## Decision
Only dev runs MLflow and the retrain job. Prod receives the exact bundle that was deployed and smoke-tested in dev, copied by the deploy workflow after a reviewer approves the `prod` environment.

## Consequences
- "Build once, promote" applies to models as well as images: what reaches prod is byte-for-byte what was tested.
- Prod has no RDS or MLflow, which removes cost and attack surface.
- Prod depends on dev for new models. This is acceptable for one team; at a larger scale the ML workspace would move to its own account.
