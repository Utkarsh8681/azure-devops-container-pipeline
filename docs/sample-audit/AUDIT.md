# Pipeline Health Audit — Sample Deliverable

**Subject:** `orders-api` — Azure DevOps pipeline, containerised .NET service deploying to Azure Container Apps
**Scope:** `azure-pipelines.yml`, `Dockerfile`, database deployment step
**Method:** Static review of pipeline and container definitions. No access to the Azure subscription, running application, or repository history.

> **This is a sample.** The subject is a synthetic fixture in
> [`subject/`](subject/), written to represent defects I have encountered in
> real pipelines. It exists so prospective clients can see the exact format and
> depth of the deliverable before commissioning one. No third-party project is
> being assessed.

---

## Summary

| Severity | Count | Headline |
|---|:--:|---|
| **Critical** | 2 | Live production credentials committed to source control; secrets baked permanently into published image layers |
| **High** | 4 | Any branch can deploy to production; no rollback path; database changes applied untracked; test failures do not block release |
| **Medium** | 5 | No security scanning of any kind; container runs as root on an SDK base image; floating and end-of-life versions |

**Overall assessment.** This pipeline works — it builds and it deploys. The
concern is not function but blast radius. Two of the findings mean credentials
should be treated as already compromised, and the deployment path has no gate
between a developer's local commit and production. Both are addressable within
a week; the credential rotation should not wait that long.

---

## Critical findings

### C1 — Production credentials hardcoded in the pipeline definition

```yaml
ACR_PASSWORD: 'Contoso!Registry2024'
DB_CONN: 'Server=prod-sql...;User Id=sa;Password=P@ssw0rd123;'
```

Also inline at the database step:

```bash
sqlcmd -S prod-sql.database.windows.net -U sa -P 'P@ssw0rd123'
```

A registry password and a production SQL `sa` credential are in version control.
Consequences worth stating plainly: they are visible to everyone with read access
to the repository, present in every clone and every fork, retained in git history
after any future edit, and rendered into build logs wherever the variable is
echoed.

**Treat both as compromised.** Removing them from the file does not undo
exposure — the values must be rotated.

**Fix.** Rotate the SQL credential and the registry password. Move both into an
Azure Key Vault–backed variable group, or use a workload identity federation
service connection so no registry password exists at all. Replace `sa` with a
scoped account holding only the permissions the deployment needs.

---

### C2 — Secrets passed as build arguments, persisting in image layers

```yaml
docker build \
  --build-arg NPM_TOKEN=$(NPM_TOKEN) \
  --build-arg DB_CONNECTION="$(DB_CONN)"
```

```dockerfile
RUN echo "//registry.npmjs.org/:_authToken=${NPM_TOKEN}" > ~/.npmrc \
    && npm install \
    && rm ~/.npmrc
```

The `rm` suggests awareness of the risk but does not resolve it. Build arguments
are recorded in image metadata and each `RUN` layer is retained independently —
deleting a file in the same layer removes it from the filesystem, not from image
history. Anyone able to pull this image can recover both the npm token and the
production connection string with `docker history --no-trunc`.

`ENV ConnectionStrings__Default=${DB_CONNECTION}` additionally writes the
connection string into the image environment, where it is readable by any process
in the container and visible in inspect output.

**Fix.** Mount build-time credentials as BuildKit secrets, which are available
to the requesting `RUN` step and written to no layer:

```dockerfile
RUN --mount=type=secret,id=npmrc,target=/root/.npmrc npm install
```

```bash
DOCKER_BUILDKIT=1 docker build --secret id=npmrc,src=.npmrc .
```

Runtime configuration such as the connection string belongs in the Container App
secret store injected at start, not in the image.

---

## High findings

### H1 — Every branch deploys to production

```yaml
trigger:
  branches:
    include:
      - '*'
```

The pipeline has one deployment step and it targets `orders-api-prod`. Any push
to any branch — a spike, a work-in-progress, a colleague's experiment — deploys
to production. There is no environment separation and no approval gate.

**Fix.** Restrict the trigger to `main`. Split deployment into stages selected
by parameter, and attach an Azure DevOps Environment with a required approval to
the production stage.

### H2 — Mutable image tag, so no rollback target exists

Every build pushes `:latest`. The consequences compound: there is no way to
determine which build is running in production, no immutable artefact to
redeploy, and rolling back requires rebuilding from a git commit and hoping the
result is identical. Because Container Apps sees an unchanged image reference, a
revision may also not restart at all.

**Fix.** Tag with `$(Build.BuildId)` or the commit SHA, and treat tags as
immutable. Push `:latest` additionally if convenient for local use, but deploy
only the immutable reference.

### H3 — Database changes applied untracked, against production, as `sa`

```bash
sqlcmd -S prod-sql... -i db/schema_changes.sql
```

A single mutable file is executed against production on every run. There is no
record of what was applied or when, no detection of an edited script, no dry-run,
and no protection against two concurrent pipeline runs interleaving. The step
also runs unconditionally before deployment, so a schema change ships whether or
not it was intended.

**Fix.** Adopt versioned migration files with a tracking table recording
filename, checksum, timestamp and environment. Refuse to proceed when a
previously applied file has changed. Gate execution behind an explicit parameter
and default to dry-run.

### H4 — Test failures do not block the pipeline

```yaml
- script: dotnet test --configuration Release
  continueOnError: true
```

The test suite runs and its result is discarded. A failing build deploys to
production identically to a passing one.

**Fix.** Remove `continueOnError`. Publish results with `PublishTestResults@2` so
failures are visible rather than buried in log output.

---

## Medium findings

| ID | Finding | Impact | Fix |
|---|---|---|---|
| M1 | No security scanning of any kind — no SAST, image scanning, secret detection, or dependency audit | Vulnerabilities and committed secrets reach production unexamined. Secret detection would have caught C1. | Add Semgrep, Trivy, and Gitleaks as a gate before build |
| M2 | Deploy has no health gate and no rollback | `az containerapp update` returns as soon as the API accepts the request, not when the revision is serving. In single revision mode the old revision stops before the new one is ready, producing intermittent 502s. A bad deploy stays live. | Force multiple revision mode, poll revision health, shift traffic only when healthy, restore prior revision on failure |
| M3 | SDK image used as runtime; container runs as root | ~700 MB versus ~200 MB, with compilers and the full SDK toolchain present in production. Root means a container escape starts with elevated privilege. | Multi-stage build onto `aspnet` runtime base; `USER app` |
| M4 | `docker system prune -a -f` on the agent | Removes all cached layers, including those belonging to other pipelines sharing the agent. Every subsequent build rebuilds from scratch. | Prune dangling images only, or omit on hosted agents |
| M5 | Floating and end-of-life versions — `ubuntu-latest`, `sdk:6.0`, `version: '6.x'` | Builds are not reproducible; an agent image change can break the build with no code change. .NET 6 left support in November 2024, so no security patches are being received. | Pin the agent image; migrate to .NET 8 LTS |

---

## Missing gates

| Gate | Present |
|---|:--:|
| Static analysis (SAST) | ✖ |
| Secret detection | ✖ |
| Container image vulnerability scan | ✖ |
| Dependency / lockfile audit | ✖ |
| Test results enforced | ✖ |
| Branch protection on deployment | ✖ |
| Environment approval before production | ✖ |
| Post-deploy health verification | ✖ |
| Rollback path | ✖ |
| Database change tracking | ✖ |

---

## Three highest-value fixes, ranked

Ranked by risk reduced per hour of work, not by severity alone.

### 1 — Remove and rotate the credentials
**Effort: 2–4 hours · Risk reduced: highest**

Rotate the SQL and registry credentials, move them to a Key Vault–backed
variable group, and switch the registry login to a workload identity service
connection. Replace `sa` with a scoped deployment account.

This is first because it is the only finding where the exposure is already live
and every day of delay extends it. It is also the cheapest fix on the list.

### 2 — Immutable tags, branch-gated deployment, enforced tests
**Effort: 1–2 days · Risk reduced: high**

Tag images with the build ID. Restrict the trigger to `main`. Split the single
job into `Build` and `Deploy` stages with an Environment approval on production.
Remove `continueOnError` from the test step.

Together these three changes convert deployment from a side effect of any push
into a deliberate act with a rollback target.

### 3 — Versioned database migrations and security gates
**Effort: 3–5 days · Risk reduced: high, sustained**

Replace the single mutable SQL file with checksum-tracked migrations, dry-run by
default. Add Semgrep, Trivy, and Gitleaks ahead of the build stage, configured to
fail on high-severity findings that have a fix available.

Last of the three because it is the largest, but it is the one that stops these
findings recurring rather than fixing them once.

---

## Deliberately not included

Ranked lower and left for a follow-up conversation: multi-stage Dockerfile size
optimisation beyond the runtime base change, layer cache configuration, parallel
build fan-out across services, SBOM generation, and consolidating the pipeline
into reusable templates. All worthwhile; none of them reduce risk as much per
hour as the three above.

---

## Assumptions and limits of this review

This was a static review of two files. I did not have access to the Azure
subscription, the running application, repository history, or the variable group
configuration. Specifically unverified:

- Whether the committed credentials are still valid
- Whether repository history contains further secrets (requires a full-history scan)
- Actual Container App scaling, ingress, and probe configuration
- Whether `NPM_TOKEN` is defined as a secret variable or in plain text

A follow-up with read access to the subscription and full git history would
confirm these and likely surface additional findings.

---

## What I would need to carry out the fixes

Repository write access on a branch, an Azure DevOps service connection with
permission to create variable groups and Environments, and a named contact who
can authorise the credential rotation. Fix 1 can begin immediately; fixes 2 and
3 are best sequenced after it.

---

*Prepared by Utkarsh Pal — Azure DevOps & CI/CD Engineer*
*[github.com/Utkarsh8681](https://github.com/Utkarsh8681) · utkarsh8671@gmail.com*
