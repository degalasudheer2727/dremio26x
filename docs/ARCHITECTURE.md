# Architecture & Design Notes (Dremio 26 v3 chart)

## The v3 platform

Dremio 26's Helm chart (`oci://quay.io/dremio/dremio-helm`, semver `3.x.x`)
deploys an **operator-based platform**, not just coordinator + executors:

```
            OpenShift Route ──▶ Service dremio-client (web 9047 / client 31010 / flight 32010)
                                     │
   ┌──────────────────────────────────────────────────────────────────────┐
   │ Coordinator (master, UID 999) ── ZooKeeper (quorum)                    │
   │      │                                                                 │
   │      ▼                                                                 │
   │ Engine operator ──▶ Executors (elastic engines) ──▶ Distributed storage│
   │                                                      (S3 / ADLS / GCS) │
   │ Catalog server + Catalog services (Iceberg REST)                       │
   │      │            │                                                    │
   │      ▼            ▼                                                    │
   │ MongoDB (Percona) + operator        OpenSearch + operator              │
   │   (catalog metadata, backups)         (semantic search)                │
   │ NATS (JetStream)        Telemetry (OTel)        DDC (diagnostics)       │
   └──────────────────────────────────────────────────────────────────────┘
```

| Component | Role | Key facts |
|-----------|------|-----------|
| Coordinator | UI/planning/JDBC/Flight | StatefulSet `dremio-master-*`; fixed UID 999 |
| Engine operator + executors | query execution; elastic engine sizing | `engine.options.sizes` (2XSmall…4XLarge) |
| ZooKeeper | coordination | 1 (dev) / 3 (qa,prod) |
| Catalog server (+ external access) | Iceberg REST catalog | needs `catalog.storage` location |
| Catalog services | catalog control plane | |
| MongoDB (Percona) + operator | catalog metadata store | `psmdb` CRDs; backup + PITR |
| OpenSearch + operator | search | needs `vm.max_map_count` node tuning |
| NATS (JetStream) | messaging | natsBox disabled on OpenShift |
| Distributed storage | reflections/results/uploads | **object storage only** |
| Telemetry / DDC | observability / diagnostics | OTel collector |

## Versions

- **Chart**: semver `3.x.x` (e.g. `3.2.3`) → `helm --version`.
- **App/image**: `26.x.x` (e.g. `26.1.3`) → `dremio.image.tag`.
- v2 charts (`dremio-cloud-tools/charts/dremio_v2`) are **incompatible** with 26.

## OpenShift security model

- **No custom SCC.** `useOpenShiftRoles: true` (in the official overrides) makes
  the chart render RoleBindings that grant its ServiceAccounts the right to use
  the built-in **`nonroot`/`nonroot-v2`** SCCs.
- Per-component ServiceAccounts are created by the chart: `dremio-coordinator`,
  `dremio-executor`, `dremio-engine-operator`, `dremio-engine-executor`,
  `zookeeper`, `dremio-catalog-server`, `dremio-catalog-services`,
  `dremio-mongodb`, `dremio-nats`, `dremio-opensearch-operator`,
  `opensearch-cluster`.
- Coordinator keeps UID 999; components that tolerate arbitrary UIDs use
  `runAsUser: null` (OpenShift assigns). See [RUNBOOK.md](RUNBOOK.md) Part A.
- OpenSearch privileged init container is disabled → `vm.max_map_count` is set
  via the **Node Tuning Operator** (`openshift/02-node-tuning-opensearch.yaml`).

## Why these repo objects

| Object | File | Reason |
|--------|------|--------|
| Namespace | `openshift/01-namespace.yaml` | project for the release |
| Tuned CR | `openshift/02-node-tuning-opensearch.yaml` | required `vm.max_map_count=262144` for OpenSearch |
| Route (UI) | `openshift/03-route-ui.yaml` | expose `dremio-client` web port (9047) |
| Route (Flight) | `openshift/04-route-flight.yaml` | optional external Arrow Flight (passthrough TLS) |

ServiceAccounts, Roles/RoleBindings, and SCC bindings are **created by the
chart** — they are intentionally not in this repo.

## What to change for production

1. Object storage for dist + a separate Iceberg `catalog.storage` location.
2. Dedicated node pools (nodeSelector/tolerations), explicit SSD/NVMe
   StorageClass.
3. End-to-end TLS (cert Secrets + reencrypt Routes).
4. 3-node ZooKeeper/MongoDB/OpenSearch (defaults), MongoDB backup+PITR, catalog
   replicas ≥ 2, executor count sized to concurrency.
5. Backups of the distributed store and verified MongoDB restore.
