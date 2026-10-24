# ADR 0003: No NAT gateway

**Status:** accepted

## Context
The standard layout puts tasks in private subnets behind NAT gateways. Each NAT gateway costs about £30/month plus data processing, more than the rest of the dev environment.

## Decision
Use public subnets only. Fargate tasks get public IPs for outbound calls (ECR, CloudWatch, Secrets Manager), and security groups admit inbound traffic only from the ALB (API) or from specific security groups (MLflow, RDS). RDS is not publicly accessible. An S3 gateway endpoint keeps S3 traffic on the AWS network for free.

## Consequences
- Much cheaper, and the security boundary is the security group rather than the subnet.
- Tasks are reachable by IP in principle, so a mistake in a security group would be exposed. The Terraform tests assert the ingress rules for this reason.
- For a production system with compliance requirements I would add private subnets with VPC interface endpoints (or a NAT), which is a contained change to `modules/network`.
