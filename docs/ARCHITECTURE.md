# Architecture & Design Notes

## Components

```
                         OpenShift cluster (namespace: dremio)
  ┌──────────────────────────────────────────────────────────────────────┐
  │                                                                        │
  │   Route(edge TLS) ─▶ Service(dremio-client) ─▶ Coordinator (master-0)  │
  │      :443→:9047                          ┌──────────┴──────────┐       │
  │                                          │ planning, UI, JDBC, │       │
  │                                          │ Arrow Flight        │       │
  │                                          └──────────┬──────────┘       │
  │                                                     │ assigns work     │
  │   ZooKeeper (zk-0) ◀── coordination ───────────────┤                  │
  │                                                     ▼                  │
  │                                            Executor(s) (executor-0)    │
  │                                                     │                  │
  │                                                     ▼                  │
  │                                   Distributed storage (PVC / S3 / ...) │
  │                                   reflections · job results · uploads  │
  └──────────────────────────────────────────────────────────────────────┘
```

- **Coordinator (master):** hosts the web UI (9047), parses & plans SQL,
  exposes JDBC/ODBC (31010) and Arrow Flight SQL (32010), and stores cluster
  metadata in a local RocksDB key-value store (its PVC).
- **Executor:** receives query fragments from the coordinator and executes
  them. Scaling out = more/larger executors. C3 “cloud cache” (off in minimal)
  caches object-storage reads on local NVMe.
- **ZooKeeper:** coordinates the cluster and elects the master. One node is fine
  for dev; use **3** for production quorum.
- **Distributed storage:** shared scratch for reflections (accelerations), job
  result sets, uploads and downloads. Minimal setup uses a PVC; production
  should use object storage (S3 / ADLS Gen2 / GCS).

## Why these OpenShift-specific objects

| Object | File | Reason |
|--------|------|--------|
| ServiceAccount | `02-serviceaccount.yaml` | A stable identity to attach the SCC to. |
| SCC | `03-scc.yaml` | OpenShift blocks fixed UIDs by default; Dremio’s image needs UID/GID 999 consistently across all pods. |
| Role + RoleBinding | `04-rbac.yaml` | Grants the ServiceAccount permission to *use* the SCC (the GitOps form of `oc adm policy add-scc-to-user`). |
| Route (UI) | `05-route-ui.yaml` | OpenShift uses Routes (not Ingress) to publish HTTP services; edge TLS terminates at the router. |
| Route (Flight) | `06-route-flight.yaml` | Arrow Flight is gRPC/HTTP2 → needs a TLS (passthrough) Route. |

## Chart lineage (important)

- Dremio **24/25** used the **v2** chart from
  `github.com/dremio/dremio-cloud-tools` (`charts/dremio_v2`). **Deprecated.**
- Dremio **26+** uses the **v3** chart published as an **OCI artifact**:
  `oci://quay.io/dremio/dremio-helm`. The v2 chart is **not compatible** with 26.
- This project targets **v3 only**. The values file mirrors the documented v3
  structure; always reconcile against `helm show values` for your exact version.

## Security posture of the minimal setup

- **Least-privilege SCC:** no host network/IPC/PID, no privilege escalation, all
  capabilities dropped, fixed non-root UID 999, scoped to one ServiceAccount in
  one namespace. It is **not** the cluster-wide `anyuid` SCC.
- **TLS:** terminated at the Route (edge) for the UI in the minimal profile, so
  in-cluster traffic is plain HTTP. For end-to-end TLS, enable TLS in the
  coordinator values and switch the Route to `reencrypt`/`passthrough`.
- **Secrets:** Enterprise pull credentials and any object-storage keys belong in
  Kubernetes Secrets, never committed to git. The values file references them by
  name only.

## What to change for production

1. ZooKeeper `count: 3`; coordinator/executor resources sized to workload.
2. `distStorage` → object storage (S3/ADLS/GCS), not a local PVC.
3. Enterprise image + license; enable TLS end-to-end.
4. Add PodDisruptionBudgets, anti-affinity, monitoring, and backups of the
   coordinator metadata volume.
