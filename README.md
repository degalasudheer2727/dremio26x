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
├── Makefile                           ← convenience targets (make help)
├── docs/
│   ├── 00-INSTALL-OPENSHIFT.md        ← MAIN spoon-fed install guide
│   ├── PREREQUISITES.md               ← tools, cluster reqs, sizing, editions
│   ├── ARCHITECTURE.md                ← components, diagrams, design rationale
│   ├── TROUBLESHOOTING.md             ← symptom → fix playbook
│   └── UNINSTALL.md                   ← teardown + upgrade procedure
├── helm/
│   └── values-openshift-minimal.yaml  ← minimal v3-chart values override
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
