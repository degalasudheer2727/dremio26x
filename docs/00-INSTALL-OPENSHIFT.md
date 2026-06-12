# Deploy Dremio 26 on OpenShift — Step‑by‑Step (Spoon‑Fed) Guide

This guide follows **Dremio's official Kubernetes/OpenShift deployment method**
for **Dremio 26** using the **v3 Helm chart** (`oci://quay.io/dremio/dremio-helm`)
and Dremio's **two‑file overrides** pattern with `useOpenShiftRoles`.

> Read this once before running `scripts/install.sh`. The script runs exactly
> these steps.

Estimated time: **45–60 minutes** on an existing cluster (the v3 platform has
several components and pulls many images).

---

## 0. What you are actually deploying

Dremio 26's v3 chart is **not** just a coordinator + executors. It deploys a full
platform, and several parts are **operators that install CRDs**:

| Component | Role | Notes |
|-----------|------|-------|
| **Coordinator** | UI (9047), planning, JDBC (31010), Flight (32010) | fixed UID 999 |
| **Executor / Engine operator** | query execution; elastic engines | `dremio-engine-operator` (CRDs) |
| **ZooKeeper** | cluster coordination | quorum in qa/prod |
| **Catalog server + Catalog services** | Iceberg REST catalog | needs its own storage location |
| **MongoDB (Percona) + operator** | catalog metadata store | `psmdb` CRDs; backups via dist storage |
| **OpenSearch + operator** | semantic search/catalog | needs `vm.max_map_count` tuning |
| **NATS (JetStream)** | internal messaging | natsBox disabled on OpenShift |
| **Distributed storage** | reflections, results, uploads | **object storage only** (S3/ADLS/GCS) |

```
        OpenShift Route (edge/reencrypt TLS) ──▶ Service dremio-client :9047
                                                      │
   Coordinator(master) ── ZooKeeper        Catalog ── MongoDB(+operator)
        │                                  Catalog services ── OpenSearch(+operator)
        ▼                                  NATS
   Engine operator ──▶ Executors ──▶ Distributed storage (S3 / ADLS / GCS)
```

### Versions — don't confuse these two
- **Helm CHART version** is semver **`3.x.x`** (e.g. `3.2.3`) → use with `--version`.
- **Dremio APP/image version** is **`26.x.x`** (e.g. `26.1.3`) → `dremio.image.tag`.

### How OpenShift security is handled (important)
You do **not** create a custom SCC. Dremio's official OpenShift overrides set
**`useOpenShiftRoles: true`**, which makes the **chart render RoleBindings** that
grant its ServiceAccounts the right to use OpenShift's built‑in **`nonroot`** and
**`nonroot-v2`** SCCs. The coordinator keeps UID 999; other components let
OpenShift assign a UID. See [RUNBOOK.md](RUNBOOK.md) Part A.

---

## 1. Prerequisites

| Tool | Version | Why |
|------|---------|-----|
| `oc` | matches cluster | OpenShift CLI |
| `helm` | **≥ 3.8** | OCI (`oci://`) chart support |

Cluster / account needs:
- **OpenShift 4.x**, a default OpenShift router, and a **default StorageClass**
  (SSD-class; NVMe for C3/spill in prod). `oc get storageclass`.
- **cluster-admin once** — to apply the OpenSearch **Node Tuning** Tuned CR
  (Step 4). Everything else is namespaced.
- Permission to **create RoleBindings** in your project (so `useOpenShiftRoles`
  can bind SCCs). Project admin normally has this.
- **Object storage** (S3 / ADLS Gen2 / GCS) for distributed storage **and** a
  (separate) location for the Iceberg catalog. There is **no local-PVC option**
  in v3.
- **Quay.io access** + an **Enterprise license** and **pull secret** (the chart
  defaults to `quay.io/dremio/dremio-enterprise`).
- For OpenSearch: nodes must allow `vm.max_map_count=262144` (Step 4).

> Run `ENV=dev ./scripts/preflight.sh` to check all of the above.

---

## 2. Log in to OpenShift

```bash
oc login https://api.YOUR-CLUSTER.example.com:6443 -u YOUR_USER
oc whoami && oc whoami --show-server
```

---

## 3. Create the project (namespace)

```bash
oc apply -f openshift/01-namespace.yaml         # creates 'dremio' (POC), or:
oc new-project dremio-dev                        # per-env convention
```

The env scripts use `dremio-dev` / `dremio-qa` / `dremio-prod`.

---

## 4. Apply OpenSearch node tuning (cluster-admin, one time)

The OpenShift overrides disable OpenSearch's privileged init container, so you
must raise `vm.max_map_count` on the nodes via the Node Tuning Operator:

```bash
oc apply -f openshift/02-node-tuning-opensearch.yaml
```

Verify after pods land (on an OpenSearch node):

```bash
oc debug node/<node> -- chroot /host sysctl vm.max_map_count   # >= 262144
```

> Not cluster-admin? Hand `openshift/02-node-tuning-opensearch.yaml` to one.
> Doing SCC/CRD work as a standalone admin task? Use [RUNBOOK.md](RUNBOOK.md).

---

## 5. Create the Enterprise pull secret + set the license

```bash
NS=dremio-dev
oc create secret docker-registry dremio-pull-secret \
  --docker-server=quay.io \
  --docker-username='YOUR_QUAY_USER' \
  --docker-password='YOUR_QUAY_TOKEN' \
  -n "$NS"
```

Put your license key in `helm/values-common.yaml` (`dremio.license: "..."`), or
keep it out of git and pass it at install time:

```bash
# license in a local file, never committed:
#   helm ... --set-file dremio.license=./dremio.license
```

---

## 6. Pin the chart version and get the authoritative defaults

Find chart versions and generate the real reference to diff against:

```bash
# helm registry login quay.io     # if your access requires auth
helm show values oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  > helm/values-reference.generated.yaml
less helm/values-reference.generated.yaml
```

> Chart keys can shift between chart minors. Our values files match chart
> **3.2.3 / app 26.1.3**; reconcile against the generated file for your version.

---

## 7. Review your environment values

Open the three files Helm will layer (order matters):

1. [`helm/values-openshift-overrides.yaml`](../helm/values-openshift-overrides.yaml)
   — Dremio's official OpenShift file (`useOpenShiftRoles`, security contexts,
   `opensearch.setVMMaxMapCount: false`, natsBox off). Usually unchanged.
2. [`helm/values-common.yaml`](../helm/values-common.yaml) — image/license/pull
   secret, `service.type: ClusterIP`.
3. `helm/values-<env>.yaml` — sizing, replica counts, **object storage**.

Set, at minimum, in the env file: `distStorage` (bucket + auth) and (prod)
`catalog.storage`. See [ENVIRONMENTS.md](ENVIRONMENTS.md).

---

## 8. Dry‑run, then install (official two‑file pattern)

```bash
NS=dremio-dev
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 3.2.3 \
  --namespace "$NS" \
  -f helm/values-openshift-overrides.yaml \
  -f helm/values-common.yaml \
  -f helm/values-dev.yaml \
  --dry-run            # validate first

helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 3.2.3 \
  --namespace "$NS" \
  -f helm/values-openshift-overrides.yaml \
  -f helm/values-common.yaml \
  -f helm/values-dev.yaml \
  --wait --timeout 30m
```

> This is exactly what `ENV=dev ./scripts/install.sh` runs.

---

## 9. Watch it come up

```bash
oc get pods -n dremio-dev -w
```

The platform starts in stages (zookeeper → mongodb/opensearch → coordinator →
executors → catalog). Give it time. Confirm each pod runs under the expected
SCC:

```bash
oc get pods -n dremio-dev -o \
  'custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
# Dremio pods should show nonroot / nonroot-v2 (NOT restricted-v2 failing)
```

Coordinator log readiness:

```bash
oc logs -f dremio-master-0 -n dremio-dev
```

Stuck pods? See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) (OpenSearch
`max_map_count`, pull-secret, object-storage auth are the usual culprits).

---

## 10. Expose the Web UI

```bash
oc get svc dremio-client -n dremio-dev          # confirm it exists
oc apply -f openshift/03-route-ui.yaml          # edit namespace if not 'dremio'
oc get route dremio-ui -n dremio-dev -o jsonpath='https://{.spec.host}{"\n"}'
```

Open the HTTPS URL → **create the admin account on first login**. 🎉

> Local access without a Route:
> `oc port-forward svc/dremio-client 9047:9047 -n dremio-dev` → http://localhost:9047

For qa/prod the UI runs TLS inside the pod — switch the Route to `reencrypt`.
Arrow Flight (32010): apply `openshift/04-route-flight.yaml` (passthrough, needs
`coordinator.flight.tls.enabled: true`). JDBC (31010) is raw TCP → use
port-forward or a LoadBalancer Service.

---

## 11. Verify

```bash
oc get statefulset,deploy,pods,pvc,svc,route -n dremio-dev
helm status dremio -n dremio-dev
oc get crd | grep -iE 'dremio|opensearch|psmdb'      # operator CRDs present
```

In the UI: run `SELECT 1` in the SQL Runner; add a sample source. A result
confirms coordinator + engine + catalog + storage are wired correctly.

---

## One‑shot automated path

```bash
ENV=dev ./scripts/preflight.sh
ENV=dev CHART_VERSION=3.2.3 ./scripts/install.sh
```

Next: [ENVIRONMENTS.md](ENVIRONMENTS.md) (dev/qa/prod), [RUNBOOK.md](RUNBOOK.md)
(SCC/CRD ops), [TROUBLESHOOTING.md](TROUBLESHOOTING.md).
