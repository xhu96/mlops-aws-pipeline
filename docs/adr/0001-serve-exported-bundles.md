# ADR 0001: Serve an exported bundle, not the registry

**Status:** accepted

## Context
The API could load models straight from MLflow (`models:/churn-classifier@champion`). That makes the serving path depend on the MLflow server and its database being up, and it means the model behind a running task can change without a deployment.

## Decision
The training job exports the champion as a small bundle (model, metadata, training data profile) to S3. The ECS task definition pins `MODEL_VERSION`, and each task downloads exactly that version at startup.

## Consequences
- The API depends only on S3. MLflow can be down, upgraded or deleted (prod has none at all) without affecting predictions.
- A task definition revision identifies one code version and one model version, so an ECS rollback restores both together.
- Changing the model requires a deploy, which runs the smoke test. This is intentional.
- The serving image does not include MLflow, which keeps it at roughly half the size of the training image.
- The bundle uses joblib (pickle). This is acceptable because only our own pipeline writes to the bucket, and the API role cannot write there.
