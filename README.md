# cicd-demo

A self-contained, laptop-runnable demonstration of a realistic **dev → stage → prod**
CI/CD pipeline for a Python web service.

- **App:** FastAPI service that reports which environment it is running in
- **CI:** GitHub Actions — lint, test, build, scan, publish, promote
- **CD:** ArgoCD (GitOps) deploying to a local **Kind** cluster
- **Environments:** three namespaces (`dev`, `stage`, `prod`) on one cluster

The point of this project is not the app — it is the **pipeline discipline**:
immutable artifacts, Git as the source of truth, environment parity, progressive
gating, and auditable, reversible promotion.

---

## Architecture

```
 push / PR
    │
    ▼
┌────────────────────┐   lint → test → build → scan → push (GHCR, tag = git SHA)
│ GitHub Actions (CI) │
└────────────────────┘
    │ commits new image tag into deploy/overlays/dev
    ▼
┌────────────────────┐   base/ + overlays/{dev,stage,prod}  (Kustomize)
│  Git (source truth) │
└────────────────────┘
    │ ArgoCD watches
    ▼
┌───────────────────────────────────────────────┐
│                Kind cluster                      │
│  ns: dev          ns: stage        ns: prod      │
│  auto-sync        auto-sync        manual sync   │
│  (every merge)    (promoted tag)   (approved)    │
└───────────────────────────────────────────────┘
```

CI builds and publishes. **ArgoCD deploys.** CI never runs `kubectl apply` — it
only writes to Git. That boundary is the core GitOps principle.

---

## Repository layout

```
cicd-demo/
├── app/                      # FastAPI service
│   ├── main.py               #   /  /healthz  /readyz  /metrics
│   └── config.py             #   12-factor env config
├── tests/                    # pytest unit tests
├── Dockerfile                # multi-stage, slim, non-root
├── pyproject.toml            # deps + ruff + pytest config
├── .github/workflows/ci.yaml # the CI pipeline
├── deploy/
│   ├── base/                 # shared Kustomize base (deployment, service)
│   ├── overlays/
│   │   ├── dev/              # 1 replica, debug logs, auto-synced
│   │   ├── stage/            # 2 replicas, prod-like, promoted tag
│   │   └── prod/             # 3 replicas, limits, PDB, anti-affinity, manual sync
│   ├── argocd/               # AppProject + 3 Application definitions
│   └── kind/cluster.yaml     # local cluster w/ ingress port mappings
├── Makefile                  # bootstrap + promotion + validation targets
└── README.md
```

---

## The three stages — and why each exists

Each stage mirrors a real production discipline. The **same immutable image**
(tagged with the Git SHA) flows through all three; only the Git tag reference
moves forward. We never rebuild per environment.

### `dev` — "Does it run at all?"
- **Sync:** automated (ArgoCD auto-sync + self-heal + prune)
- **Trigger:** every merge to `main`, within seconds
- **Config:** 1 replica, minimal resources, `LOG_LEVEL=debug`
- **Why:** fast feedback. Breakage here is cheap and expected. This is where
  latest-main always lives.

### `stage` — "Does it behave like prod?"
- **Sync:** automated, but the image tag only advances on a **deliberate promotion**
- **Config:** 2 replicas, prod-like resources, `LOG_LEVEL=info`
- **Why:** pre-production validation. Catches issues that only show up with
  prod-like config and scale. This is the release-candidate gate (QA/UAT/smoke).

### `prod` — "Controlled, deliberate release"
- **Sync:** **manual** — a human clicks Sync in ArgoCD (or `argocd app sync`)
- **Config:** 3 replicas, strict limits, `LOG_LEVEL=warn`, PodDisruptionBudget,
  pod anti-affinity
- **Why:** protect the live environment. Nothing reaches prod without a
  deliberate, auditable decision (who approved, which SHA). This is change control.

---

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- Python 3.11+
- A GitHub account (`ntcct`) for GHCR publishing when you wire up CI

---

## Quick start (local app only)

```bash
make install     # install app + dev deps
make test        # run unit tests
make lint        # ruff lint + format check
make run         # serve on http://localhost:8000
```

Then visit `http://localhost:8000/` — it reports `"environment": "local"`.

---

## Full demo (Kind + ArgoCD)

```bash
make demo              # create cluster, install ingress + ArgoCD, register apps
make argocd-password   # print the ArgoCD admin password
make argocd-ui         # open the UI at https://localhost:8080 (user: admin)
```

Once ArgoCD syncs, the environments are reachable at (no /etc/hosts edits needed —
`localtest.me` resolves to 127.0.0.1):

- http://dev.cicd-demo.localtest.me
- http://stage.cicd-demo.localtest.me
- http://prod.cicd-demo.localtest.me  *(after a manual prod sync)*

Each URL returns the environment it belongs to, proving they are distinct
deployments of the same image.

> Note: before the first real deploy you must publish an image to GHCR (push to
> `main` so CI builds it) and let CI bump the dev overlay's tag. Until then the
> overlays reference a placeholder tag `sha-000000000000`.

---

## The promotion flow (what the demo proves)

1. **Push code** → CI runs lint → test → build → **scan** → publish image tagged
   with the Git SHA to `ghcr.io/ntcct/cicd-demo`.
2. **Merge to main** → CI's `promote-dev` job commits the new tag into
   `deploy/overlays/dev` → ArgoCD auto-syncs → `dev.…` shows the new version.
3. **Promote to stage** (deliberate):
   ```bash
   make promote-stage     # copies dev's tag into the stage overlay
   git commit -am "promote to stage" && git push
   ```
   ArgoCD auto-syncs stage with the **same, already-tested image**.
4. **Promote to prod** (deliberate + approved):
   ```bash
   make promote-prod      # copies stage's tag into the prod overlay
   git commit -am "promote to prod" && git push
   argocd app sync cicd-demo-prod   # MANUAL — the human gate
   ```
5. **Break something** → a failing test or a CRITICAL/HIGH CVE blocks the build;
   it never reaches any cluster.
6. **Rollback** → revert the GitOps commit; ArgoCD syncs back to the previous SHA.

Each step maps to a real production discipline: immutable artifacts, GitOps
source-of-truth, environment parity, progressive gating, and auditable rollback.

---

## Validate manifests without a cluster

```bash
make validate      # renders dev/stage/prod overlays with kustomize
```

---

## CI secrets / permissions

The workflow uses the built-in `GITHUB_TOKEN` with `packages: write` (push to
GHCR) and `contents: write` (commit the dev tag bump). No extra secrets are
required for the single-repo setup. For GHCR to be writable, ensure the repo's
package settings allow Actions to publish.

---

## Out of scope (possible extensions)

Argo Rollouts (blue/green or canary), external secrets, real TLS, a persistent
database, and multi-cluster separation. These are deliberately omitted to keep
the demo focused; each can be layered on later.
