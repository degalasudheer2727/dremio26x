# Environment Values: dev · qa · prod (Dremio 26 v3 chart)

The values are layered in the order Dremio's official guide requires —
**OpenShift overrides first**, then shared, then the environment overlay:

```
helm/values-openshift-overrides.yaml   ← Dremio's official OpenShift file (useOpenShiftRoles, security contexts)
   + helm/values-common.yaml            ← image / license / pull secret / service type
   + helm/values-<env>.yaml             ← sizing, replica counts, object storage
```

Install (per environment, into its own namespace):

```bash
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 3.2.3 \
  --namespace dremio-<env> \
  -f helm/values-openshift-overrides.yaml \
  -f helm/values-common.yaml \
  -f helm/values-<env>.yaml --wait
# or:
ENV=dev make install
```

> **Versions:** chart = `3.x.x` (e.g. `3.2.3`), app/image = `26.x.x` (e.g. `26.1.3`).

---

## At a glance

| Setting | dev | qa | prod |
|---|---|---|---|
| **Purpose** | smallest that runs the full platform | smaller mirror of prod | production |
| **Namespace** | `dremio-dev` | `dremio-qa` | `dremio-prod` |
| **Coordinator** | 2 CPU / 8 Gi | 8 CPU / 32 Gi | **32 CPU / 64 Gi** (Dremio rec.) |
| **Executors** | 1 × (2/8) | 2 × (8/32) | **3 × (16/128)** (1:8) |
| **Cloud Cache (C3)** | off | 50 Gi | 100 Gi (NVMe) |
| **ZooKeeper** | 1 | 3 | 3 |
| **MongoDB (catalog meta)** | 1, no backup | 3 + backup | 3 + backup + PITR |
| **OpenSearch** | 1, 2g heap | 3, 6g heap | 3, 10g heap |
| **Catalog / Catalog svc** | 1 / 1 | 1 / 1 | 2 / 2 |
| **Dist storage** | object storage* | object storage | object storage |
| **TLS** | edge (Route) | edge/reencrypt | end-to-end (reencrypt) |
| **Node pools** | shared | shared | dedicated (nodeSelector + tolerations) |
| **Image / edition** | Enterprise | Enterprise | Enterprise |

\* The v3 chart has **no local-PVC dist storage** — every environment needs an
object store (S3/ADLS/GCS or an S3-compatible store such as MinIO for dev).

---

## Why each environment is shaped this way

### dev
Single replicas and shrunken resources for every component, MongoDB backups off,
OpenSearch on a 2 GB heap. Still the full platform (you cannot meaningfully run
Dremio 26 without catalog + MongoDB + OpenSearch + NATS). Dev points dist
storage at an in-cluster MinIO by default — change it to your store.

### qa
Quorum everywhere (ZooKeeper/MongoDB/OpenSearch = 3), real object storage, edge
or reencrypt TLS, moderate resources. Validates the same topology and the same
Enterprise image you will ship to prod.

### prod — aligned with Dremio's production recommendations
The v3 chart defaults are already production-grade, so this overlay mainly pins
the things you must own:
- **Coordinator 32 vCPU / 64 Gi**, **executors 16 vCPU / 128 Gi × 3** (Dremio's
  recommended sizing; raise `executor.count` for more concurrency).
- **Cloud Cache (C3)** on NVMe; **3-node** ZooKeeper / MongoDB / OpenSearch.
- **MongoDB backups + PITR** on; catalog/catalog-services at 2 replicas.
- **Object storage** for dist storage **and** a separate Iceberg catalog
  location (`catalog.storage`).
- **End-to-end TLS** (set `*.tls.enabled: true`, provide cert Secrets, Route =
  reencrypt).
- **Dedicated node pools** via `nodeSelector` + `tolerations` (label/taint nodes
  `dremio-node-type=coordinator|executor`, `dremio-dedicated=...`).
- Explicit **StorageClass** (gp3/io2 · managed-premium · pd-ssd).

---

## Prod prerequisites checklist

1. **Object storage** (dist) + **separate catalog location**, with IAM /
   workload identity preferred over static keys (keys → Kubernetes Secret only).
2. **Enterprise pull secret** (`dremio-pull-secret`) in the namespace + license.
3. **OpenSearch node tuning** applied (`openshift/02-node-tuning-opensearch.yaml`).
4. **Dedicated node pools** labelled & tainted to match `values-prod.yaml`:
   ```bash
   oc label node <n> dremio-node-type=executor
   oc adm taint node <n> dremio-dedicated=executor:NoSchedule
   ```
5. **StorageClass** set explicitly (SSD for data, NVMe for C3/spill).
6. **TLS cert Secrets** created (`dremio-tls-secret-ui`, `...-client`,
   `...-flight`, `...-catalog`) if enabling TLS.
7. **Backups**: MongoDB backups to dist storage are on; also protect the
   distributed store and verify restore. Metadata upgrades are one-way
   (see [UNINSTALL.md](UNINSTALL.md)).

---

## Reconcile before qa/prod

```bash
helm show values oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  > helm/values-reference.generated.yaml
helm template dremio oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  -f helm/values-openshift-overrides.yaml -f helm/values-common.yaml \
  -f helm/values-prod.yaml -n dremio-prod | less
```

Confirm every key you override exists in the generated reference for your exact
chart version (`distStorage`, `catalog.storage`, `cloudCache.volumes`,
`mongodb.*`, `opensearch.*` can shift between chart minors).
