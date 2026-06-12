# dremio26x — Dremio 26 Minimal Deployment on OpenShift (Helm v3 chart)

A complete, ready-to-run project for deploying a **minimal Dremio 26** cluster on
**Red Hat OpenShift** using the **official Dremio Helm v3 chart**
(`oci://quay.io/dremio/dremio-helm`) plus the OpenShift-specific objects
(ServiceAccount, SCC, RBAC, Routes) that Dremio needs to run there.

> **New here? Go straight to the spoon-fed, step-by-step guide:**
> 👉 **[docs/00-INSTALL-OPENSHIFT.md](docs/00-INSTALL-OPENSHIFT.md)**

---

## TL;DR — install in three commands

```bash
# 0. clone, then from the repo root:
./scripts/preflight.sh                              # check you're ready
oc apply -f openshift/                              # namespace, SA, SCC, RBAC (SCC needs cluster-admin)
DREMIO_CHART_VERSION=26.0.0 ./scripts/install.sh    # helm install + expose UI Route
```

Then open the printed `https://…` URL and create the admin account on first
login.

> Prefer doing it by hand to understand each step? Follow
> [docs/00-INSTALL-OPENSHIFT.md](docs/00-INSTALL-OPENSHIFT.md) instead — the
> script just runs those same commands.

---

## What’s in this repo

```
dremio26x/
├── README.md                          ← you are here
├── Makefile                           ← convenience targets (make help, ENV=dev|qa|prod)
├── docs/
│   ├── 00-INSTALL-OPENSHIFT.md        ← MAIN spoon-fed install guide
│   ├── RUNBOOK.md                     ← SCC + CRD execution runbook (admin ops)
│   ├── ENVIRONMENTS.md                ← dev/qa/prod values design + comparison
│   ├── PREREQUISITES.md               ← tools, cluster reqs, sizing, editions
│   ├── ARCHITECTURE.md                ← components, diagrams, design rationale
│   ├── TROUBLESHOOTING.md             ← symptom → fix playbook
│   └── UNINSTALL.md                   ← teardown + upgrade procedure
├── helm/
│   ├── values-common.yaml             ← shared base (layered under each env)
│   ├── values-dev.yaml                ← dev overlay  (single node, local PVC, OSS)
│   ├── values-qa.yaml                 ← qa overlay   (smaller mirror of prod)
│   ├── values-prod.yaml               ← prod overlay (Dremio production setup)
│   └── values-openshift-minimal.yaml  ← single-file POC profile (≈ common+dev)
├── openshift/
│   ├── 01-namespace.yaml              ← project/namespace
│   ├── 02-serviceaccount.yaml         ← dedicated ServiceAccount
│   ├── 03-scc.yaml                    ← least-privilege SecurityContextConstraint (UID 999)
│   ├── 04-rbac.yaml                   ← Role/RoleBinding granting 'use' of the SCC
│   ├── 05-route-ui.yaml               ← Route exposing the Web UI (9047)
│   └── 06-route-flight.yaml           ← (optional) Route for Arrow Flight (32010)
└── scripts/
    ├── preflight.sh                   ← read-only readiness checks
    ├── install.sh                     ← end-to-end install wrapper
    └── uninstall.sh                   ← teardown (keep or PURGE data)
```

---

## Environments: dev / qa / prod

Values are designed as a shared base plus per-environment overlays
(`values-common.yaml` + `values-<env>.yaml`), installed into separate
namespaces (`dremio-dev` / `dremio-qa` / `dremio-prod`):

| Env  | Topology                                   | Storage        | Edition     | TLS / HA |
|------|--------------------------------------------|----------------|-------------|----------|
| dev  | 1 coord · 1 exec · 1 ZK (2 CPU/8 Gi)       | local PVC      | OSS (free)  | edge TLS, no HA |
| qa   | 1 coord · 2 exec · 3 ZK (smaller-than-prod)| object storage | Enterprise* | e2e TLS, quorum |
| prod | 1 coord · 3 exec · 3 ZK (~16 CPU/120 Gi)   | object storage | Enterprise  | e2e TLS, quorum, anti-affinity, dedicated node pools |

```bash
make install ENV=dev      # or qa / prod
make dry-run ENV=prod     # render only, no changes
make status  ENV=qa
```

**Production aligns with Dremio's recommended production setup** — see
[docs/ENVIRONMENTS.md](docs/ENVIRONMENTS.md) for the full comparison, rationale,
prod prerequisites checklist, and a PodDisruptionBudget template.

## Key facts about Dremio 26 on Kubernetes

- **Helm v3 chart, distributed over OCI:** `oci://quay.io/dremio/dremio-helm`.
  Requires **Helm ≥ 3.8**.
- The **older v2 chart** (`github.com/dremio/dremio-cloud-tools/charts/dremio_v2`)
  is **NOT compatible with Dremio 26** — do not use it.
- **OpenShift specifics:** pods must run as a fixed UID (the image’s `dremio`
  user, UID 999), which the default `restricted-v2` SCC forbids. This project
  ships a tightly-scoped SCC bound to a dedicated ServiceAccount to satisfy that
  without granting cluster-wide `anyuid`.
- **Editions:** defaults to the free **OSS** image (`dremio/dremio-oss`); switch
  to the **Enterprise** image (`quay.io/dremio/dremio-enterprise` + license +
  pull secret) by editing `helm/values-openshift-minimal.yaml`.

## Endpoints

| Purpose            | Port  | Exposed via            |
|--------------------|-------|------------------------|
| Web UI             | 9047  | Route (edge TLS)       |
| JDBC / ODBC        | 31010 | port-forward / LB Service (raw TCP — not a Route) |
| Arrow Flight SQL   | 32010 | optional passthrough Route |

---

## ⚠️ Important accuracy note about the values file

`helm/values-openshift-minimal.yaml` follows Dremio’s documented v3-chart
structure (`coordinator` / `executor` / `zookeeper` / `distStorage` / `image` /
`serviceAccount`). Because individual key names can shift between chart minor
versions, **always generate the authoritative reference for your exact version
and reconcile** before installing:

```bash
helm show values oci://quay.io/dremio/dremio-helm --version 26.0.0 \
  > helm/values-reference.generated.yaml
```

The install guide builds this into the procedure (Step 6).

---

## Sources / further reading

- [Deploy Dremio on Kubernetes — Dremio Docs](https://docs.dremio.com/current/deploy-dremio/deploy-on-kubernetes/)
- [Configuring Your Values to Deploy Dremio to Kubernetes — Dremio Docs](https://docs.dremio.com/current/deploy-dremio/configuring-kubernetes/)
- [Red Hat OpenShift — Dremio Docs](https://docs.dremio.com/current/deploy-dremio/kubernetes-deployment-options/red-hat-openshift/)
- [dremio/dremio-cloud-tools (legacy v2 chart, reference only)](https://github.com/dremio/dremio-cloud-tools)
