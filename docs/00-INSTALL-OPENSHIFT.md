# Deploy Dremio 26 on OpenShift — Step‑by‑Step (Spoon‑Fed) Guide

This guide walks you, **one command at a time**, through deploying a **minimal
Dremio 26** cluster on **Red Hat OpenShift** using the **Helm v3 chart** that
Dremio ships for version 26+.

> **Read this once before running `scripts/install.sh`.** The script does
> exactly what this guide does — but you should understand each step.

Estimated time: **30–45 minutes** on a cluster that already exists.

---

## 0. Mental model — what are we building?

A minimal Dremio cluster has four moving parts:

| Component       | What it does                                   | How many (minimal) |
|-----------------|------------------------------------------------|--------------------|
| **Coordinator** | Web UI (9047), planning, JDBC/ODBC (31010), Arrow Flight (32010) | 1 (also master) |
| **Executor**    | Runs the actual query work                     | 1                  |
| **ZooKeeper**   | Cluster coordination / leader election         | 1                  |
| **Dist storage**| Shared storage for reflections, job results, uploads | PVC (local)  |

```
                 ┌─────────────────────────────────────────┐
   You ──HTTPS──▶│ OpenShift Route (edge TLS)               │
                 └───────────────┬─────────────────────────┘
                                 ▼  :9047
                 ┌─────────────────────────────────────────┐
                 │ Coordinator (master)  ── ZooKeeper       │
                 │      │                                   │
                 │      ▼                                   │
                 │ Executor(s) ──▶ Distributed storage (PVC)│
                 └─────────────────────────────────────────┘
```

### About “Helm + operator”
For Dremio **26+, the Helm v3 chart *is* the supported, operator‑style install
path.** It is published as an **OCI artifact on Quay** (`oci://quay.io/dremio/
dremio-helm`) and manages the full Dremio control plane (StatefulSets, services,
config) for you. The older **v2** chart from the `dremio-cloud-tools` GitHub repo
is **not compatible with Dremio 26** — do not use it. There is no separate
OperatorHub/OLM operator required for this minimal install.

---

## 1. Prerequisites (your workstation)

You need these CLIs locally:

| Tool   | Minimum version | Why                                   | Get it |
|--------|-----------------|---------------------------------------|--------|
| `oc`   | matches cluster | OpenShift CLI                         | OpenShift web console → **?** → *Command line tools* |
| `helm` | **3.8+**        | OCI registry support (`oci://`)       | https://helm.sh/docs/intro/install/ |

Check them:

```bash
oc version --client
helm version          # must report v3.8.0 or newer
```

You also need:

- **Access to an OpenShift cluster** (4.x) and the `oc login` command for it.
- **cluster‑admin** rights *once*, to create the SecurityContextConstraint
  (SCC) in Step 4. If you are not an admin, hand `openshift/03-scc.yaml` and
  `openshift/04-rbac.yaml` to one and ask them to apply them.
- **A default StorageClass** that can dynamically provision `ReadWriteOnce`
  PersistentVolumes. Check with `oc get storageclass`.
- **Network egress to `quay.io`** from wherever you run `helm` (to pull the
  chart) and from the cluster nodes (to pull images), or a mirror/proxy.

> **Shortcut:** run `./scripts/preflight.sh` — it checks all of the above and
> tells you what is missing.

---

## 2. Log in to OpenShift

Copy your login command from the OpenShift web console
(top‑right **▾ username → Copy login command**), or:

```bash
oc login https://api.YOUR-CLUSTER.example.com:6443 -u YOUR_USER
```

Confirm:

```bash
oc whoami
oc whoami --show-server
```

---

## 3. Create the project (namespace) and ServiceAccount

```bash
oc apply -f openshift/01-namespace.yaml
oc apply -f openshift/02-serviceaccount.yaml
```

Verify:

```bash
oc get project dremio
oc get sa dremio -n dremio
```

> **Why a dedicated ServiceAccount?** OpenShift normally assigns each pod a
> *random* UID. Dremio’s coordinator, executors and ZooKeeper must all run as
> the **same** user so they can read each other’s files on the shared volumes.
> We pin that user via an SCC in the next step, bound to this ServiceAccount.

---

## 4. Grant the SCC (needs cluster‑admin, one time)

The Dremio image runs as **UID/GID 999**. OpenShift’s default `restricted-v2`
SCC forbids that. We apply a **tightly‑scoped** SCC that lets **only** the
`dremio` ServiceAccount run as UID 999, and bind it via RBAC.

```bash
oc apply -f openshift/03-scc.yaml      # the SecurityContextConstraint
oc apply -f openshift/04-rbac.yaml     # Role + RoleBinding that grants 'use'
```

Verify the binding (equivalent to `oc adm policy add-scc-to-user`):

```bash
oc get scc dremio-scc
oc auth can-i use scc/dremio-scc \
   --as=system:serviceaccount:dremio:dremio -n dremio   # -> yes
```

> Not a cluster‑admin? Send `openshift/03-scc.yaml` and `04-rbac.yaml` to one.
> They are safe: the SCC applies to a single ServiceAccount in one namespace,
> grants no host access, and drops all Linux capabilities.

---

## 5. (Enterprise only) Create an image pull secret

**Skip this if you use the free OSS image** (`dremio/dremio-oss`, the default in
the values file). For the **Enterprise** image on Quay you need credentials:

```bash
oc create secret docker-registry dremio-pull-secret \
  --docker-server=quay.io \
  --docker-username='YOUR_QUAY_USER' \
  --docker-password='YOUR_QUAY_TOKEN' \
  -n dremio

# link it to the ServiceAccount so pods can pull:
oc secrets link dremio dremio-pull-secret --for=pull -n dremio
```

Then in `helm/values-openshift-minimal.yaml` set the enterprise image and
uncomment `image.pullSecrets: [dremio-pull-secret]`.

---

## 6. Get the authoritative chart defaults (and pin a version)

List available chart versions and pin one — never deploy “latest” to anything
you care about:

```bash
# If quay requires auth for the chart, log in first (usually NOT needed for OSS):
# helm registry login quay.io

# See the chart's real default values for YOUR target version:
helm show values oci://quay.io/dremio/dremio-helm --version 26.0.0 \
  > helm/values-reference.generated.yaml
```

Open `helm/values-reference.generated.yaml` and skim it. Then **diff** our
minimal override against it to make sure every key we set actually exists in
this chart version:

```bash
# eyeball that keys like coordinator/executor/zookeeper/distStorage/image match
less helm/values-reference.generated.yaml
```

> **Why:** key names occasionally shift between chart minor versions.
> `helm/values-openshift-minimal.yaml` follows the documented structure, but the
> generated file above is the source of truth for *your* version. If a key
> differs, edit the override to match before installing.

---

## 7. Review the minimal values override

Open [`helm/values-openshift-minimal.yaml`](../helm/values-openshift-minimal.yaml)
and confirm/adjust:

- `image.tag` → the exact Dremio 26 tag you want (e.g. `26.0.0`).
- `storageClass` → leave `""` for the cluster default, or set a specific class.
- CPU/memory → defaults are small (2 CPU / 8 Gi each). Lower them only for a tiny
  lab; raise them for real workloads.
- `distStorage.type` → `local` (PVC) for minimal; switch to `aws`/`azure`/`gcp`
  for production object storage.

> Do **not** set `runAsUser`/`fsGroup` in the values on OpenShift — the SCC
> supplies UID/GID 999. Overriding it will cause permission errors.

---

## 8. Dry‑run, then install

Validate before touching the cluster:

```bash
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 26.0.0 \
  --namespace dremio \
  --values helm/values-openshift-minimal.yaml \
  --dry-run
```

If the render is clean, install for real:

```bash
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 26.0.0 \
  --namespace dremio \
  --values helm/values-openshift-minimal.yaml \
  --wait --timeout 15m
```

> `upgrade --install` is **idempotent**: it installs on first run and upgrades
> on later runs. Re‑run the same command after editing values to apply changes.

---

## 9. Watch it come up

```bash
oc get pods -n dremio -w
```

Wait until every pod is `Running` and `READY` shows full (e.g. `1/1`). Expect
something like:

```
NAME                       READY   STATUS    RESTARTS   AGE
dremio-master-0            1/1     Running   0          3m
dremio-executor-0          1/1     Running   0          3m
zk-0                       1/1     Running   0          3m
```

If a pod is stuck `Pending`, it is almost always **PVC/StorageClass** related —
see [TROUBLESHOOTING](TROUBLESHOOTING.md). Tail logs with:

```bash
oc logs -f dremio-master-0 -n dremio
```

The master is ready when the log prints a line like
`Dremio Daemon Started as master`.

---

## 10. Expose the Web UI with a Route

First find the service the chart created for client/UI traffic:

```bash
oc get svc -n dremio
```

Note the client service name (commonly `dremio-client`). If it matches, apply
the Route as‑is; otherwise edit `to.name` in the file first:

```bash
oc apply -f openshift/05-route-ui.yaml
```

Get your URL:

```bash
oc get route dremio-ui -n dremio -o jsonpath='https://{.spec.host}{"\n"}'
```

Open that HTTPS URL in a browser. **On first login Dremio asks you to create the
admin account** — set a username/email and a strong password. Done. 🎉

> No external traffic / can’t use Routes? Reach the UI locally instead:
> ```bash
> oc port-forward svc/dremio-client 9047:9047 -n dremio
> # then open http://localhost:9047
> ```

---

## 11. (Optional) Expose JDBC and Arrow Flight

- **Arrow Flight SQL (32010):** apply `openshift/06-route-flight.yaml`. This uses
  **passthrough** TLS, so you must enable Flight TLS in the values
  (`coordinator.flight.tls.enabled: true`) for it to work end‑to‑end.
- **JDBC/ODBC (31010):** this is raw TCP and **cannot** go through an HTTP Route.
  For external access create a `LoadBalancer`/`NodePort` Service, or for local
  testing use:
  ```bash
  oc port-forward svc/dremio-client 31010:31010 -n dremio
  ```

---

## 12. Verify it actually works

```bash
# All workloads healthy?
oc get statefulset,pods,pvc,svc,route -n dremio

# Helm thinks the release is deployed?
helm status dremio -n dremio
```

Then in the Web UI: log in → **Add Source → Sample Source** (or upload a small
CSV) → run `SELECT 1` in the SQL Runner. A returned result confirms the
coordinator + executor + storage path are all wired correctly.

---

## Day‑2 quick reference

| Task                     | Command |
|--------------------------|---------|
| Change config / resources| edit `helm/values-openshift-minimal.yaml`, re‑run the Step‑8 `upgrade --install` |
| Scale executors          | set `executor.count`, re‑run upgrade |
| Upgrade Dremio version   | bump `image.tag` **and** `--version`, see [UNINSTALL/upgrade notes](../docs/TROUBLESHOOTING.md) and Dremio’s upgrade docs |
| View logs                | `oc logs -f dremio-master-0 -n dremio` |
| Uninstall (keep data)    | `./scripts/uninstall.sh` |
| Uninstall (delete data)  | `PURGE=1 ./scripts/uninstall.sh` |

---

## One‑shot automated path

If you have read the above and just want it done:

```bash
./scripts/preflight.sh                       # check readiness
DREMIO_CHART_VERSION=26.0.0 ./scripts/install.sh
```

See [`README.md`](../README.md) for the file map and
[`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) when something misbehaves.
