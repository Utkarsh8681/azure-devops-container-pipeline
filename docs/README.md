# Documentation

## [Pipeline Health Audit — sample deliverable](sample-audit/AUDIT.md)

A worked example of the written assessment I produce for a pipeline audit:
severity-ranked findings with evidence, a missing-gates checklist, and three
fixes ranked by risk reduced per hour of effort.

The subject is a synthetic fixture in [`sample-audit/subject/`](sample-audit/subject/)
— a pipeline and Dockerfile written to contain defects I have encountered in real
projects. Using a fixture rather than a real third-party repository is
deliberate: the findings demonstrate the method, and no one's project is
publicly assessed without their involvement.

**Reading order**

1. [`sample-audit/subject/azure-pipelines.yml`](sample-audit/subject/azure-pipelines.yml) — the pipeline under review
2. [`sample-audit/subject/Dockerfile`](sample-audit/subject/Dockerfile) — the container definition under review
3. [`sample-audit/AUDIT.md`](sample-audit/AUDIT.md) — the findings

For contrast, the pipeline at the root of this repository is the same delivery
problem solved correctly. Each finding in the audit maps to a design decision
documented in the [main README](../README.md).
