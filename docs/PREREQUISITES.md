# Prerequisites & Sizing (Dremio 26 v3 chart)

## Workstation tools

| Tool | Version | Notes |
|------|---------|-------|
| `oc` | matches cluster | OpenShift CLI |
| `helm` | **≥ 3.8** | OCI (`oci://`) chart support (mandatory) |
| `git` | any | clone this repo |

```bash
oc version --client && helm version
```

## Cluster requirements

- **OpenShift 4.x** with the default router (Routes) and built-in `nonroot` /
  `nonroot-v2` SCCs (present by default).
- **cluster-admin once** to apply the OpenSearch **Tuned CR**
  (`openshift/02-node-tuning-opensearch.yaml`). CRDs (engine/MongoDB/OpenSearch
  operators) are also cluster-scoped — Helm installs them, but creating/upgrading
  them needs admin. See [RUNBOOK.md](RUNBOOK.md).
- **Permission to create RoleBindings** in your project (so `useOpenShiftRoles`
  can bind the SCCs).
- **Dynamic StorageClass** (`ReadWriteOnce`, expandable). `oc get storageclass`.
  Prod: SSD for data, **NVMe for C3/spill**.
- **Object storage** (S3 / ADLS Gen2 / GCS, or S3-compatible like MinIO) for
  distributed storage **and** a separate Iceberg catalog location. There is **no
  local-PVC dist storage** in v3.
- **Quay.io egress** (chart + Enterprise images), or a mirror for air-gapped.

## Editions / images

The chart defaults to the **Enterprise** image
(`quay.io/dremio/dremio-enterprise:26.x`), which needs a **license** and a
**pull secret** (`dremio-pull-secret`). Companion images (busybox, utils,
catalog, MongoDB/Percona, OpenSearch, NATS, OTel) are also pulled from quay.

```bash
oc create secret docker-registry dremio-pull-secret \
  --docker-server=quay.io --docker-username='<user>' --docker-password='<token>' \
  -n <namespace>
```

## OpenSearch node tuning (required)

The OpenShift overrides disable the privileged init container, so nodes must set
`vm.max_map_count=262144` via the Node Tuning Operator:

```bash
oc apply -f openshift/02-node-tuning-opensearch.yaml
```

## Minimal (dev) footprint

`values-dev.yaml` shrinks every component to single replicas:

| Component | Replicas | CPU | Mem | Disk |
|-----------|----------|-----|-----|------|
| Coordinator | 1 | 2 | 8 Gi | 32 Gi |
| Executor | 1 | 2 | 8 Gi | 32 Gi |
| ZooKeeper | 1 | 0.5 | 1 Gi | 8 Gi |
| Catalog / Catalog svc | 1 / 1 | 1 / 1 | 2 / 2 Gi | – |
| MongoDB | 1 | 0.5–1 | 1 Gi | 32 Gi |
| OpenSearch | 1 | 1 | 4 Gi | 32 Gi |
| NATS | 1 | 0.5 | 1 Gi | 2 Gi |

Even "minimal" Dremio 26 needs **~10+ CPU and ~30+ Gi RAM** schedulable plus
object storage — it is a platform, not a single pod.

## Production sizing (Dremio recommendations)

| Component | Size | Instance hint |
|-----------|------|---------------|
| Coordinator | 32 vCPU / 64 Gi | c6i.8xlarge · Standard_F32s_v2 |
| Executor | 16 vCPU / 128 Gi (1:8) or 32/128 (1:4) | memory-optimized |
| Storage | gp3/io2 · managed-premium · pd-ssd; **NVMe for C3 + spill** | |

3-node ZooKeeper / MongoDB / OpenSearch; MongoDB backup + PITR; catalog replicas
≥ 2; dedicated node pools. See [ENVIRONMENTS.md](ENVIRONMENTS.md).
