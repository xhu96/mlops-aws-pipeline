# Post-mortem: input drift after a price rise (game-day drill)

> **This was a planned drill on the local stack, not a production incident.** It is reproducible with `./scripts/incident_drill.sh`; every number below comes from that run. The format is a blameless post-mortem, written the way I would for a real one.

| | |
|---|---|
| Date | 2026-10-24 |
| Severity | SEV-3: predictions available, quality at risk |
| Detection | daily drift job, alarm `churn-dev-data-drift` |
| Time to mitigate | one retrain + deploy cycle |
| Customer impact | for the drill period, churn scores computed on inputs outside the training distribution |

## Summary
A simulated price rise moved monthly charges up by about £22 on average, increased support tickets and pushed customers to month-to-month contracts. The model kept answering but was now scoring a population it had not been trained on: predicted churners jumped from 247 to 602 per 1000 customers. The drift job flagged three features. A first, rushed retrain used mislabelled data and was rejected by the quality gate. A second retrain on recent, correctly labelled data passed, was deployed as v3, and the drift check returned to green.

## Timeline
| Step | What happened |
|---|---|
| T0 | v1 serving. 1000 normal customers, drift check OK (max PSI 0.018). |
| T1 | Traffic changes: 1000 customers after the price rise. Predicted churners: 247 → 602. |
| T2 | Drift job fails with `status: drift`, max PSI **1.055**. Drifted: `monthly_charges` (1.055), `support_tickets` (0.899), `contract_type` (0.360). Alarm fires. |
| T3 | Retrain on a data extract later found to have 40% flipped labels. Gate **blocks** it: ROC AUC 0.634 vs minimum 0.75 and vs champion 0.875. Nothing deployed. |
| T4 | Retrain on recent, clean data (v3). Gate passes: ROC AUC 0.871 on the frozen holdout, within the 0.01 tolerance of v1. Promoted to `@champion`, exported, API redeployed serving v3. |
| T5 | Same post-price-rise traffic against v3: drift check OK (max PSI 0.017), because v3's profile reflects the new distribution. |
| T6 | Rollback rehearsed: `@champion` v3 → v1 → v3. |

## What went well
- **Detection was automatic.** No one had to notice that scores looked odd; PSI per feature pointed straight at the cause.
- **The gate stopped a bad model.** Under pressure to "just retrain", a corrupted training set produced a model with AUC 0.63. It never reached the API.
- **Recovery used the normal path**: the same retrain and deploy pipeline as any other day, no manual steps.
- **Rollback is one command**, and was rehearsed rather than assumed.

## What went badly
- The alert says *that* inputs moved, not *whether accuracy dropped*. We only know the true churn outcome weeks later, so we could not quantify the real impact.
- The rushed retrain shows the gate is the only defence against bad labels. A data validation step before training would catch this earlier and more cheaply.
- The drift check is daily. A change at 09:00 is not seen until 06:00 the next day.

## Action items
| Action | Type | Status |
|---|---|---|
| Validate training data before training (label balance, nulls, ranges) and fail fast | prevent | open |
| Join captured predictions with real outcomes to track live ROC AUC | detect | open |
| Run the drift job every 6 hours in prod | detect | open |
| Add a "drift explained" note to the runbook template so business changes are announced to the ML team in advance | process | done ([runbook](../runbook.md#data-drift)) |
| Keep `scripts/incident_drill.sh` in the repo and rerun it after pipeline changes | process | done |
