# CI/CD — GitHub Actions (CI) + Argo CD GitOps (CD)

This project is **CI/CD native**: every change is validated by CI on the way in,
and deployed by **pull-based GitOps** (Argo CD / OpenShift GitOps) on the way
out. Nobody runs `helm install` by hand in qa/prod — you change git, Argo CD
reconciles the cluster to match.

```
   PR ──▶ GitHub Actions CI ──▶ merge ──▶ Argo CD watches git ──▶ cluster
          (lint, render,                  dev: auto-sync
           kubeconform,                   qa : auto-sync (no prune)
           gitleaks)                      prod: MANUAL sync (gated)
```

---

## 1. CI — `.github/workflows/ci.yaml`

Runs on every PR and on pushes to `main` / `claude/**`:

| Job | What it gates |
|-----|---------------|
| `lint` | `yamllint` (config: `.yamllint.yaml`) + `shellcheck` on `scripts/*.sh` |
| `secret-scan` | `gitleaks` — fails if a credential is committed |
| `values-structure` | every values/manifest is valid YAML; greps for inline license/keys |
| `render` (matrix dev/qa/prod) | `helm template` the **real chart** with our 3 layered values files, then `kubeconform` schema-validates the output |
| `validate-openshift-manifests` | `kubeconform` on `openshift/` + `gitops/` manifests |

**Quay access in CI:** the `render` job pulls the chart from quay.io. It runs
only if the repo has `QUAY_USERNAME` / `QUAY_TOKEN` secrets; without them it
**skips** (the lint/scan/static jobs still gate the PR). Add them in
*Settings → Secrets and variables → Actions* to enable full chart rendering and
the key-reconcile check.

Keep `CHART_VERSION` in `ci.yaml` in sync with the chart version used in
`helm/` and `gitops/`.

---

## 2. CD — Argo CD GitOps (`gitops/`)

```
gitops/
├── bootstrap/app-of-apps.yaml        ← the ONE thing an admin applies
├── projects/dremio-project.yaml      ← AppProject (allowed repos/namespaces/CRDs)
└── applications/
    ├── dremio-prereqs.yaml           ← cluster prereq: OpenSearch Tuned CR (auto)
    ├── dremio-dev.yaml               ← auto-sync + self-heal
    ├── dremio-qa.yaml                ← auto-sync, no prune/self-heal
    └── dremio-prod.yaml              ← MANUAL sync (promotion gate)
```

Each env Application is **multi-source** (Argo CD ≥ 2.6 / OpenShift GitOps ≥ 1.8):
source #1 is this git repo (provides the layered values via the `$values` ref),
source #2 is the Dremio **OCI Helm chart**. Argo renders the chart with the same
three files as the official install:

```yaml
helm:
  valueFiles:
    - $values/helm/values-openshift-overrides.yaml
    - $values/helm/values-common.yaml
    - $values/helm/values-<env>.yaml
```

### Sync behaviour per environment

| Env | automated | prune | selfHeal | CRDs |
|-----|-----------|-------|----------|------|
| dev | yes | yes | yes | chart installs (`skipCrds: false`) |
| qa | yes | no | no | pre-staged by admin (`skipCrds: true`) |
| prod | **no (manual)** | – | – | pre-staged/upgraded by admin |

---

## 3. Bootstrap (one time)

```bash
# 1) Install the Red Hat OpenShift GitOps (Argo CD) operator from OperatorHub.
#    It creates the `openshift-gitops` namespace + an Argo CD instance.

# 2) Register the Dremio OCI Helm registry in Argo CD WITH credentials
#    (the Enterprise chart/images on quay need auth):
argocd repo add quay.io/dremio --type helm --enable-oci \
  --username '<quay-user>' --password '<quay-token>'

# 3) Apply the app-of-apps. From here, git is the source of truth.
oc apply -f gitops/bootstrap/app-of-apps.yaml
```

Argo CD then creates the AppProject and all env Applications. dev/qa/prereqs
sync automatically; prod waits for a manual sync.

> Set `targetRevision` in each Application: a branch (e.g. `main`) for dev/qa,
> and an **immutable tag/commit** for prod.

---

## 4. Promotion flow

1. Open a PR changing a value (image tag, replica count, sizing, …). CI renders
   and validates all three envs.
2. Merge → Argo CD **auto-syncs dev**. Verify in the dev namespace.
3. Promote to qa: qa tracks the same branch and auto-syncs (no prune). Validate.
4. Promote to prod: bump prod's `targetRevision` to the reviewed tag (PR), then
   **manually sync** `dremio-prod` in a change window:
   ```bash
   argocd app sync dremio-prod
   argocd app wait dremio-prod --health
   ```

A separate-branch-per-env or separate-values-repo model also works; this repo
uses one branch + per-env Applications for simplicity.

---

## 5. Secrets — never in git

CI actively fails the build if a license/credential looks committed. Provide
these to the cluster out-of-band, referenced by name from the values:

| Secret | Used by | How to supply |
|--------|---------|---------------|
| `dremio-pull-secret` | image pulls (`imagePullSecrets`) | `oc create secret docker-registry …` per namespace, or **External Secrets** from a vault |
| Dremio license | `dremio.license` | Secret + a chart license option, or `--set-file` outside GitOps; do NOT put in `values-common.yaml` |
| Object-storage creds | `distStorage.*.credentials.secretName` | Secret per env, or IAM/workload identity (`authentication: metadata`) — preferred |
| TLS certs | `*.tls.secret` (qa/prod) | cert-manager or a created Secret |

Recommended GitOps-friendly options: **External Secrets Operator** (sync from
Vault/cloud secret managers) or **Sealed Secrets** (encrypted in git). Either
keeps the GitOps "everything in git" property without exposing plaintext.

---

## 6. Local equivalent (no Argo CD)

The scripts/Makefile run the identical layered install for clusters without
GitOps:

```bash
ENV=dev make dry-run      # same render CI does
ENV=dev make install
```
