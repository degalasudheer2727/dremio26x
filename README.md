# dremio26x — Dremio 26 on OpenShift (official v3 Helm chart)

A complete, ready-to-run project for deploying **Dremio 26** on **Red Hat
OpenShift** the way **Dremio's official guide** prescribes: the **v3 Helm chart**
(`oci://quay.io/dremio/dremio-helm`) installed with Dremio's **two-file overrides**
pattern and **`useOpenShiftRoles`** (so the chart wires up the OpenShift SCCs),
with dev / qa / prod environment overlays.

> **New here? Go straight to the spoon-fed, step-by-step guide:**
> 👉 **[docs/00-INSTALL-OPENSHIFT.md](docs/00-INSTALL-OPENSHIFT.md)**

---

## TL;DR

```bash
# from the repo root, logged into OpenShift:
ENV=dev ./scripts/preflight.sh                       # check readiness

# one-time, cluster-admin: OpenSearch node tuning
oc apply -f openshift/02-node-tuning-opensearch.yaml

# create the Enterprise pull secret in the namespace
oc create secret docker-registry dremio-pull-secret \
  --docker-server=quay.io --docker-username='<user>' --docker-password='<token>' \
  -n dremio-dev

# install (layered overrides, official two-file pattern + our env overlay)
ENV=dev CHART_VERSION=3.2.3 ./scripts/install.sh
```

Then open the printed `https://…` URL and create the admin account.

> **Versions:** Helm **chart** = `3.x.x` (e.g. `3.2.3`); Dremio **app/image** =
> `26.x.x` (e.g. `26.1.3`). Don't confuse them — `--version` takes the chart's.

---

## What's in this repo

```
dremio26x/
├── README.md                            ← you are here
├── Makefile                             ← make help, ENV=dev|qa|prod
├── docs/
│   ├── 00-INSTALL-OPENSHIFT.md          ← MAIN spoon-fed install guide
│   ├── CICD.md                          ← GitHub Actions CI + Argo CD GitOps CD
│   ├── RUNBOOK.md                       ← SCC (useOpenShiftRoles) + CRD/operator runbook
│   ├── ENVIRONMENTS.md                  ← dev/qa/prod values design + comparison
│   ├── PREREQUISITES.md                 ← tools, cluster reqs, sizing, editions
│   ├── ARCHITECTURE.md                  ← v3 platform components + rationale
│   ├── TROUBLESHOOTING.md               ← symptom → fix playbook
│   └── UNINSTALL.md                     ← teardown + upgrade procedure
├── .github/workflows/ci.yaml            ← CI: lint, render, kubeconform, gitleaks
├── gitops/                              ← Argo CD GitOps (app-of-apps, per-env Apps)
│   ├── bootstrap/app-of-apps.yaml       ← the one manifest an admin applies
│   ├── projects/dremio-project.yaml     ← Argo CD AppProject
│   └── applications/                    ← dremio-{prereqs,dev,qa,prod}.yaml
├── helm/
│   ├── values-openshift-overrides.yaml  ← Dremio's OFFICIAL OpenShift overrides (layer FIRST)
│   ├── values-common.yaml               ← image / license / pull secret / service type
│   ├── values-dev.yaml                  ← dev overlay  (single replicas, small)
│   ├── values-qa.yaml                   ← qa overlay   (quorum, smaller-than-prod)
│   └── values-prod.yaml                 ← prod overlay (Dremio production sizing)
├── openshift/
│   ├── 01-namespace.yaml                ← project/namespace
│   ├── 02-node-tuning-opensearch.yaml   ← REQUIRED vm.max_map_count Tuned CR
│   ├── 03-route-ui.yaml                 ← Route exposing the Web UI (9047)
│   └── 04-route-flight.yaml             ← (optional) Route for Arrow Flight (32010)
└── scripts/
    ├── preflight.sh                     ← read-only readiness checks
    ├── install.sh                       ← end-to-end install wrapper
    └── uninstall.sh                     ← teardown (keep or PURGE data)
```

---

## Environments: dev / qa / prod

Values layer in the order Dremio requires — **OpenShift overrides → common →
env** — into separate namespaces (`dremio-dev` / `dremio-qa` / `dremio-prod`):

| Env  | Coord / Exec | ZK · Mongo · OpenSearch | Storage | TLS / HA |
|------|--------------|-------------------------|---------|----------|
| dev  | 2/8 · 1×(2/8) | 1 · 1 · 1 | object store (e.g. MinIO) | edge TLS, no HA |
| qa   | 8/32 · 2×(8/32) | 3 · 3 · 3 | object store | edge/reencrypt, quorum |
| prod | 32/64 · 3×(16/128) | 3 · 3 · 3 | object store + Iceberg catalog | e2e TLS, dedicated node pools |

```bash
make install ENV=dev      # or qa / prod
make dry-run ENV=prod     # render only
make status  ENV=qa
```

**Production aligns with Dremio's recommended production sizing** — see
[docs/ENVIRONMENTS.md](docs/ENVIRONMENTS.md).

## CI/CD native

- **CI (GitHub Actions, `.github/workflows/ci.yaml`):** on every PR — `yamllint`
  + `shellcheck`, `gitleaks` secret scan, `helm template` the real chart with
  the layered values for **all three envs**, and `kubeconform` schema-validation.
- **CD (Argo CD GitOps, `gitops/`):** apply one app-of-apps and the cluster
  reconciles from git — **dev** auto-syncs, **qa** auto-syncs without prune,
  **prod** is a **manual sync** promotion gate. Each env is a multi-source
  Application (OCI Helm chart + this repo's values).

```bash
# bootstrap GitOps (after installing the OpenShift GitOps operator):
argocd repo add quay.io/dremio --type helm --enable-oci --username '<u>' --password '<t>'
oc apply -f gitops/bootstrap/app-of-apps.yaml
```

Full details, promotion flow, and secret handling: **[docs/CICD.md](docs/CICD.md)**.

## Key facts about Dremio 26 on OpenShift

- **v3 Helm chart over OCI:** `oci://quay.io/dremio/dremio-helm` (chart `3.x.x`,
  app `26.x.x`). Requires **Helm ≥ 3.8**. The old **v2** chart is **incompatible**.
- **It's a platform, not a pod:** coordinator + elastic engines (engine
  operator) + ZooKeeper + Iceberg catalog + **MongoDB (Percona) + OpenSearch +
  NATS**, several with **operators/CRDs**.
- **OpenShift security:** no custom SCC — `useOpenShiftRoles: true` makes the
  chart bind its ServiceAccounts to the built-in **`nonroot`/`nonroot-v2`** SCCs.
- **OpenSearch needs node tuning:** `vm.max_map_count=262144` via the Node Tuning
  Operator (`openshift/02-node-tuning-opensearch.yaml`).
- **Object storage is mandatory** (S3/ADLS/GCS); there is **no local-PVC** dist
  storage in v3. The Iceberg catalog needs its own location too.
- **Enterprise image by default** (`quay.io/dremio/dremio-enterprise`) → license
  + `dremio-pull-secret` required.

## Endpoints

| Purpose | Port | Exposed via |
|---------|------|-------------|
| Web UI | 9047 | Route (edge or reencrypt) |
| JDBC / ODBC | 31010 | port-forward / LB Service (raw TCP — not a Route) |
| Arrow Flight SQL | 32010 | optional passthrough Route |

---

## ⚠️ Accuracy note

These values match chart **`3.2.3`** / app **`26.1.3`**. Key names can shift
between chart minors, so generate the authoritative reference for your version
and reconcile before installing:

```bash
helm show values oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  > helm/values-reference.generated.yaml
```

---

## Sources / further reading

- [Deploy Dremio on Kubernetes — Dremio Docs](https://docs.dremio.com/current/deploy-dremio/deploy-on-kubernetes/)
- [Configuring Your Values to Deploy Dremio to Kubernetes — Dremio Docs](https://docs.dremio.com/current/deploy-dremio/configuring-kubernetes/)
- [Red Hat OpenShift — Dremio Docs](https://docs.dremio.com/current/deploy-dremio/kubernetes-deployment-options/red-hat-openshift/)
- [Administer Dremio on Kubernetes — Dremio Docs](https://docs.dremio.com/current/admin/admin-dremio-kubernetes/)
