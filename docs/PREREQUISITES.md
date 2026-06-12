# Prerequisites & Sizing

A consolidated checklist. The install guide ([00-INSTALL-OPENSHIFT.md](00-INSTALL-OPENSHIFT.md))
references this.

## Workstation tools

| Tool   | Version | Notes |
|--------|---------|-------|
| `oc`   | 4.x, matching your cluster | Download from the OpenShift console → *Command line tools*. |
| `helm` | **≥ 3.8** | OCI (`oci://`) support is mandatory for the Dremio 26 v3 chart. |
| `git`  | any     | To clone this repo. |

Verify:
```bash
oc version --client
helm version
```

## Cluster requirements

- **OpenShift 4.x** with the default OpenShift router (for Routes).
- **cluster-admin** access **once**, to create the `SecurityContextConstraints`
  object (`openshift/03-scc.yaml`). Namespaced objects can be applied by a
  project admin afterward.
- A **dynamic StorageClass** providing `ReadWriteOnce` volumes. List with:
  ```bash
  oc get storageclass
  ```
  If `distStorage` is run with multiple replicas you may need `ReadWriteMany`.
- **Egress to `quay.io`**:
  - from the machine running `helm` → to pull the **chart**;
  - from the cluster nodes → to pull the **container images**
    (`docker.io/dremio/dremio-oss` for OSS, `quay.io/dremio/dremio-enterprise`
    for Enterprise).
  - Air-gapped? Mirror the chart and images into your internal registry and
    update `image.registry`/`image.repository` + the `helm` chart reference.

## Minimal resource footprint

The values in `helm/values-openshift-minimal.yaml` request approximately:

| Component   | Replicas | CPU each | Mem each | Disk each |
|-------------|----------|----------|----------|-----------|
| Coordinator | 1        | 2        | 8 Gi     | 32 Gi     |
| Executor    | 1        | 2        | 8 Gi     | 32 Gi     |
| ZooKeeper   | 1        | 0.5      | 1 Gi     | 8 Gi      |
| Dist (local)| 1 PVC    | –        | –        | 64 Gi     |

**Cluster total (roughly):** ~4.5 CPU, ~17 Gi RAM schedulable, ~136 Gi storage.

> These are dev/POC sizes. Dremio’s recommended production executor is far
> larger (commonly 15 CPU / ~120 Gi). Raise `cpu`/`memory`/`volumeSize` in the
> values before any serious workload.

## Editions

| Edition | Image | License | Helm chart |
|---------|-------|---------|------------|
| Community/OSS | `docker.io/dremio/dremio-oss:26.x` | none | same v3 chart |
| Enterprise    | `quay.io/dremio/dremio-enterprise:26.x` | required + pull secret | same v3 chart |

This project defaults to **OSS** so you can deploy with no license. Switch the
`image` block and add a pull secret (install guide Step 5) for Enterprise.
