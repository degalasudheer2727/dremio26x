# Environment Values: dev · qa · prod

This project ships a **layered** Helm values design:

```
helm/values-common.yaml      ← shared by every environment (ports, SA, image policy)
   + helm/values-dev.yaml     ← dev overlay
   + helm/values-qa.yaml      ← qa overlay   (faithful, smaller mirror of prod)
   + helm/values-prod.yaml    ← prod overlay (Dremio production recommendations)
```

Helm merges multiple `--values` files left-to-right, so you always install with
**common + one overlay**:

```bash
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 26.0.0 \
  --namespace dremio-<env> \
  --values helm/values-common.yaml \
  --values helm/values-<env>.yaml
```

The tooling does this for you:

```bash
ENV=dev   make install      # or qa / prod
ENV=prod  ./scripts/install.sh
```

> The original single-file `helm/values-openshift-minimal.yaml` still works for
> a quick POC; it is functionally equivalent to **common + dev**.

---

## At a glance

| Setting                | dev                  | qa                          | prod                                  |
|------------------------|----------------------|-----------------------------|---------------------------------------|
| **Purpose**            | fast, disposable     | faithful pre-prod mirror    | production                            |
| **Image / edition**    | `dremio-oss` (free)  | `dremio-enterprise`*        | `dremio-enterprise`                   |
| **Namespace (convention)** | `dremio-dev`     | `dremio-qa`                 | `dremio-prod`                         |
| **Coordinator**        | 2 CPU / 8 Gi         | 4 CPU / 16 Gi               | 16 CPU / ~120 Gi                      |
| **Coordinator disk**   | 32 Gi                | 100 Gi                      | 256 Gi                                |
| **Executors**          | 1 × (2 CPU / 8 Gi)   | 2 × (8 CPU / 32 Gi)         | 3 × (16 CPU / ~120 Gi)                |
| **Cloud Cache (C3)**   | off                  | on (50 Gi)                  | on (100 Gi, NVMe)                     |
| **ZooKeeper**          | 1 (no quorum)        | 3 (quorum)                  | 3 (quorum, hard anti-affinity)        |
| **Dist storage**       | local PVC (64 Gi)    | object storage (S3/ADLS/GCS)| object storage (S3/ADLS/GCS)          |
| **TLS**                | edge only (Route)    | end-to-end                  | end-to-end                            |
| **Anti-affinity**      | none                 | soft (executors)            | hard (executors + ZK)                 |
| **Node pools**         | shared               | shared (optional selectors) | dedicated (nodeSelector + tolerations)|
| **QoS**                | burstable            | burstable                   | guaranteed (size requests==limits)    |
| **Data durability**    | disposable           | recoverable                 | backed up (metadata PVC + dist store) |

\* QA defaults to the Enterprise image so it validates the exact artifact prod
runs. If you have no license, switch QA's `image` block to the dev OSS image.

---

## Why each environment is shaped this way

### dev — "smallest thing that runs"
Single coordinator, single executor, single ZooKeeper, local PVC for distributed
storage, no TLS, OSS image. Optimized for spin-up/tear-down speed; **data is
disposable**. Not safe for anything you care about (single ZK = no quorum).

### qa — "a smaller prod"
Mirrors prod **topology** so you test the real failure modes before shipping:
3-node ZooKeeper quorum, object-storage dist store, end-to-end TLS, soft
anti-affinity, and the **same Enterprise image** as prod. Only the resource
sizes and executor count are reduced to keep it affordable. If it breaks in QA,
it would have broken in prod.

### prod — aligned with Dremio's production setup
- **HA coordination:** 3 ZooKeeper nodes with hard anti-affinity so losing one
  node keeps quorum.
- **Production-sized engines:** ~16 vCPU / ~120 Gi per coordinator and executor,
  matching Dremio's recommended executor profile; ≥3 executors to start.
- **Cloud Cache (C3)** on NVMe/SSD to accelerate object-storage reads.
- **Object storage** (S3/ADLS Gen2/GCS) for the distributed store — never a
  local PVC — so reflections/results survive pod rescheduling and scale.
- **End-to-end TLS** (Route uses reencrypt/passthrough; Dremio terminates TLS).
- **Guaranteed QoS**: keep requests == limits so the scheduler never evicts
  Dremio under pressure.
- **Dedicated node pools** via `nodeSelector` + `tolerations` (label/taint your
  nodes `dremio-node-type=coordinator|executor` and `dremio-dedicated=...`).
- **Hard anti-affinity + zone spread** so a node/zone loss can't take out the
  cluster.

---

## Prod prerequisites checklist

1. **Object storage** bucket/container provisioned, with **IAM role / workload
   identity** preferred over static keys. Static keys → Kubernetes Secret only.
2. **Enterprise pull secret** created and linked (install guide Step 5).
3. **Enterprise license** supplied via the chart's license value/Secret
   (see `helm/values-reference.generated.yaml`).
4. **Dedicated node pools** labeled and tainted to match `values-prod.yaml`:
   ```bash
   oc label node <node> dremio-node-type=executor
   oc adm taint node <node> dremio-dedicated=executor:NoSchedule
   ```
5. **StorageClass** set explicitly (SSD for metadata; NVMe for C3 cache).
6. **Backups**: snapshot the coordinator metadata PVC and protect the dist
   store; metadata upgrades are one-way (see [UNINSTALL.md](UNINSTALL.md)).

---

## PodDisruptionBudget (prod)

The chart may not expose a PDB. If not, apply these AFTER install — **verify the
label selector** against your pods first (`oc get pod --show-labels -n
dremio-prod`) and adjust `matchLabels` to match the chart's actual labels:

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: dremio-zookeeper
  namespace: dremio-prod
spec:
  minAvailable: 2                 # keep ZK quorum during node drains
  selector:
    matchLabels:
      app: zookeeper              # <-- confirm with `oc get pod --show-labels`
---
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: dremio-executor
  namespace: dremio-prod
spec:
  maxUnavailable: 1
  selector:
    matchLabels:
      app: dremio-executor        # <-- confirm with `oc get pod --show-labels`
```

---

## Reconcile keys before QA/prod

`antiAffinity`, `nodeSelector`, `tolerations`, `cloudCache.storageClass`, and the
`distStorage`/license sub-keys can differ across v3 chart minor versions. Always
generate and diff the authoritative reference first:

```bash
helm show values oci://quay.io/dremio/dremio-helm --version 26.0.0 \
  > helm/values-reference.generated.yaml
helm template dremio oci://quay.io/dremio/dremio-helm --version 26.0.0 \
  -f helm/values-common.yaml -f helm/values-prod.yaml -n dremio-prod | less
```
