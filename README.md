# Azure DevOps → Container Apps: production delivery pipeline

A reference implementation of the pipeline pattern I use to ship containerised
services to Azure. One pipeline definition covers every service and every
environment, with security gates and controlled database migrations built into
the delivery path rather than bolted on beside it.

This repository is a working template, not a tutorial. Every design decision in
it exists because the obvious alternative failed in production somewhere.

---

## The problems this solves

**Pipeline duplication.** Teams commonly end up with `azure-pipelines-dev.yml`,
`azure-pipelines-uat.yml`, `azure-pipelines-prod.yml`, which drift apart until
production behaves differently from staging for reasons nobody can reconstruct.
Here, environments are boolean parameters against a single definition.

**Deployments that cause brief outages.** Container Apps in single revision mode
terminates the old revision as the new one starts. Requests arriving in that
window return 502. This pipeline forces multiple revision mode, waits for the
new revision to report healthy, and only then shifts traffic.

**Credentials leaking into image layers.** `COPY .npmrc .` puts an auth token in
the image history permanently — deleting the file in a later layer does not
remove it. Here the token is mounted as a BuildKit secret, available to the
build step that needs it and present in no layer.

**Database changes with no controlled path to production.** Schema edits applied
by hand, no record of what ran where, no way to detect that a migration was
edited after it was applied. The included runner tracks every applied file by
SHA256 and refuses to proceed if one has changed.

---

## Layout

```
azure-pipelines.yml              Entry point. Stages, parameters, environment
                                 targeting.

templates/
  build-and-push.yml             Container build, credential-leak check,
                                 image scan, push, image-reference artifact.
  security-scan.yml              Gitleaks, Semgrep, Trivy in one job.
  deploy-container-app.yml       Revision-aware deploy with health gate and
                                 automatic traffic rollback.

docker/Dockerfile                Multi-stage .NET build with BuildKit secret
                                 mount and non-root runtime user.

db/
  migrate.sh                     Checksum-tracked migration runner.
  migrations/                    Example migrations showing lock-safe patterns.

docs/
  sample-audit/                  Worked pipeline audit against a synthetic
                                 flawed pipeline. Shows the review method and
                                 the format of the written findings.
```

**See also:** [Pipeline Health Audit — sample deliverable](docs/sample-audit/AUDIT.md).
Each finding in that audit corresponds to one of the design decisions below,
which is the clearest way to see why they exist.

---

## Pipeline flow

```
                    ┌──────────────┐
                    │   VALIDATE   │  restore, format, security scans
                    └──────┬───────┘
                           │  fails fast — no image built if gates fail
                    ┌──────▼───────┐
                    │    BUILD     │  one parallel job per service
                    └──────┬───────┘
                           │  image reference published as artifact
                    ┌──────▼───────┐
                    │   MIGRATE    │  optional; dry-run by default
                    └──────┬───────┘
                           │  schema ready before new code arrives
        ┌──────────────────┼──────────────────┐
        ▼                  ▼                  ▼
   ┌─────────┐        ┌─────────┐        ┌─────────┐
   │   DEV   │        │   UAT   │        │  PROD   │
   └─────────┘        └─────────┘        └─────────┘
   selected independently via boolean parameters
```

---

## Design decisions

### Boolean environment targeting instead of one pipeline per environment

```yaml
parameters:
  - name: deployDev
    type: boolean
    default: true
  - name: deployProd
    type: boolean
    default: false
```

Stages are conditionally compiled with `${{ if eq(parameters.deployProd, true) }}`.
A run that does not target production contains no production stage at all — it
is absent from the compiled pipeline rather than skipped at runtime, so there is
no path by which it can execute accidentally.

### Multi-select services via an object parameter

```yaml
- name: services
  type: object
  default:
    - name: api
      containerApp: ca-api
    - name: worker
      containerApp: ca-worker
```

`${{ each service in parameters.services }}` fans out one job per service. A run
can rebuild a single worker without touching the rest of the estate. Adding a
service is a change to the default list, not a new pipeline.

### `az containerapp` rather than the `AzureContainerApps@1` task

The task has a fallback: when it cannot resolve the image reference it will build
from source instead. That fallback means a misconfigured registry reference can
deploy something other than the artifact the pipeline just produced — and it
succeeds, so nothing alerts. Explicit CLI calls fail loudly.

### Health gate before traffic shift, rollback after

The previously active revision is recorded before anything changes. The new
revision is polled until the platform reports it healthy. Only then does traffic
move. If any subsequent step fails, traffic returns to the recorded revision,
which is still running because of multiple revision mode. Rollback needs no
rebuild and no redeploy.

### Security gates fail on high severity *with a fix available*

```yaml
--severity HIGH,CRITICAL --ignore-unfixed --exit-code 1
```

Blocking on unfixable CVEs teaches teams to disable the gate, which is worse
than not having one. `--ignore-unfixed` keeps the signal actionable. All three
scanners run in a single job so the layer cache is shared and the gate costs one
job's queue time rather than three.

Gitleaks needs `fetchDepth: 0` — it scans commit history, and a shallow clone
silently narrows coverage to the most recent commit.

### Migrations tracked by checksum, applied fix-forward

```sql
CREATE TABLE schema_migrations (
    filename    TEXT     NOT NULL UNIQUE,
    checksum    CHAR(64) NOT NULL,
    applied_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
    environment TEXT     NOT NULL,
    duration_ms INTEGER
);
```

Four properties that matter:

- **Checksums, not filenames.** Tracking filenames alone means an edited
  migration is silently skipped and environments diverge with no error. SHA256
  makes that condition loud and blocking.
- **Fix-forward, not rollback.** Applied migrations are immutable; corrections
  are new migrations. Down-migrations are appealing in theory and unreliable
  against production data.
- **Advisory lock.** Two concurrent runs against the same database would
  otherwise interleave. `pg_try_advisory_lock` serialises them.
- **Per-file transaction.** The migration and its tracking row commit together,
  so the table can never claim a migration that only partly applied.

`--dry-run` is the default in the pipeline. It reports what would run without
touching anything, which makes the production migration a reviewed decision
rather than a side effect of a deploy.

---

## Using it

```bash
# 1. Point the parameters at your services
#    Edit the `services` default in azure-pipelines.yml

# 2. Create the service connections referenced by the deploy stages
#    sc-dev, sc-uat, sc-prod

# 3. Create variable groups for database credentials
#    db-dev, db-prod  →  pgHost, pgDatabase, pgUser, pgPassword

# 4. Migrations can be run locally against any environment
export PGHOST=localhost PGDATABASE=appdb PGUSER=postgres PGPASSWORD=...

./db/migrate.sh --dir db/migrations --env dev --dry-run   # report only
./db/migrate.sh --dir db/migrations --env dev             # apply
```

### Adapting to other stacks

The pipeline is container-oriented, not .NET-specific. To use it with Node,
Python, or Go, replace `docker/Dockerfile` and the `Validate` stage's restore
step. The build, scan, migrate, and deploy templates are unchanged — they operate
on images and environments, not on languages.

To deploy to App Service or AKS instead of Container Apps, replace
`templates/deploy-container-app.yml`. Its interface is the contract: it accepts
an image reference and an environment, and it either succeeds or restores the
previous state.

---

## Notes on things that commonly break

| Symptom | Cause |
|---|---|
| `--secret` ignored, build fails on mount | `DOCKER_BUILDKIT=1` not set on the agent |
| `addgroup: command not found` | Ubuntu-based .NET images have no busybox; use `groupadd`/`useradd` |
| `MSB3202: project file does not exist` | Restoring a single project in a multi-project solution; restore at solution level |
| Intermittent 502 during rollout | Single revision mode; old revision drops before new one is ready |
| E401 from private npm feed inside build | Token not reaching the build; authenticate on the agent, mount as secret |
| Gitleaks finds nothing on a dirty repo | `fetchDepth: 1`; history not present to scan |

---

## Licence

MIT. Use it, fork it, adapt it.
