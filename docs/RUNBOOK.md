# Operational Runbook — SCC & CRD Execution (Dremio 26 v3)

Operations runbook for the security- and operator-level parts of a Dremio 26
install on OpenShift: the **SCC** model (`useOpenShiftRoles`) and the **CRDs**
the v3 chart's operators install. These are the steps most likely to need a
cluster-admin, documented in isolation with verify + rollback.

> Full install flow: [00-INSTALL-OPENSHIFT.md](00-INSTALL-OPENSHIFT.md).
> Environment design: [ENVIRONMENTS.md](ENVIRONMENTS.md).

---

## 0. Roles & ordering

| Step | Object | Scope | Who |
|------|--------|-------|-----|
| 1 | OpenSearch Tuned CR (`vm.max_map_count`) | cluster | cluster-admin |
| 2 | CRDs (engine / MongoDB / OpenSearch operators) | cluster | cluster-admin (Helm installs `crds/`) |
| 3 | Namespace | cluster | project-admin |
| 4 | Pull secret + license | namespaced | project-admin |
| 5 | `helm install` → SCC RoleBindings via `useOpenShiftRoles` | namespaced | project-admin (needs RoleBinding rights) |

**Cluster-scoped, admin-owned objects (Tuned CR, CRDs) go in first; the Helm
release last.** There is **no custom SCC to create** — that is the key
difference from a hand-rolled deployment.

---

# PART A — SCC Execution Runbook

## A1. The model: `useOpenShiftRoles`, not a custom SCC

Dremio's official `values-openshift-overrides.yaml` sets:

```yaml
useOpenShiftRoles: true
```

With this on, the **chart itself renders RoleBindings** that grant each Dremio
ServiceAccount permission to *use* OpenShift's built-in **`nonroot`** and
**`nonroot-v2`** SCCs. You do **not** define, name, or apply any SCC yourself.

Verified RoleBindings the chart creates (names from the chart's own tests):

```
allow-dremio-coordinator-accounts-to-use-nonroot
allow-dremio-coordinator-accounts-to-use-nonroot-v2
allow-dremio-executor-accounts-to-use-nonroot
allow-dremio-executor-accounts-to-use-nonroot-v2
# plus, per legacy engine:
allow-dremio-engine-<engine>-use-nonroot
allow-dremio-engine-<engine>-to-use-nonroot-v2
```

UID strategy (from the overrides):
- **Coordinator** keeps fixed **UID/GID 999** (`runAsUser: 999`) — `nonroot-v2`
  permits a non-root UID the pod requests.
- **Engine operator, catalog, opensearch, zookeeper, mongodb hooks** set
  `runAsUser: null` → OpenShift assigns a UID from the namespace range.
- **MongoDB** runs as UID 1001 with `fsGroup: 999`.

## A2. Pre-execution checks (read-only)

```bash
NS=dremio-dev
oc whoami
# Built-in SCCs exist (they always do on OpenShift 4.x):
oc get scc nonroot nonroot-v2
# Can the installer create the RoleBindings the chart needs?
oc auth can-i create rolebindings.rbac.authorization.k8s.io -n "$NS"   # -> yes
```

## A3. Execute

There is no separate SCC step — it happens **during `helm install`** because
`useOpenShiftRoles: true` is in the overrides. Just ensure that file is layered:

```bash
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  -n "$NS" \
  -f helm/values-openshift-overrides.yaml \
  -f helm/values-common.yaml \
  -f helm/values-dev.yaml --wait
```

## A4. Verify

```bash
NS=dremio-dev
# The RoleBindings exist:
oc get rolebinding -n "$NS" | grep -E 'nonroot'

# Each pod was admitted under nonroot / nonroot-v2 (NOT restricted-v2 crashing):
oc get pods -n "$NS" -o \
  'custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'

# A specific SA may use nonroot-v2:
oc auth can-i use scc/nonroot-v2 \
  --as=system:serviceaccount:$NS:dremio-coordinator -n "$NS"      # -> yes
```

## A5. SCC failure playbook

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pods admitted to `restricted-v2` and crash on UID | `useOpenShiftRoles` not set / overrides file not layered | re-run install with `-f helm/values-openshift-overrides.yaml` first |
| `forbidden: ... cannot create rolebindings` at install | installer lacks RBAC | grant the installer RoleBinding rights, or have an admin install |
| `nonroot-v2` not found | non-OpenShift cluster, or removed SCC | this method is OpenShift-only; restore the built-in SCC |
| MongoDB/OpenSearch pod permission errors | overrides not applied for those components | confirm the full official overrides file is used (not a trimmed copy) |

## A6. Rollback

`helm uninstall` removes the chart-created RoleBindings along with everything
else. Nothing cluster-scoped to clean up for the SCC layer (the built-in SCCs
remain, untouched).

---

# PART B — CRD Execution Runbook

## B1. Which CRDs the v3 chart brings

Dremio 26's v3 platform is operator-based. Expect CRDs from up to three
operators (exact groups are version-specific — confirm with B2):

| Operator (image) | Purpose | CRD group (typical) |
|------------------|---------|---------------------|
| `dremio-engine-operator` | elastic query engines | `*.dremio.com` |
| `dremio-mongodb-operator` (Percona) | MongoDB replica set for catalog metadata | `psmdb.percona.com` (e.g. `perconaservermongodbs`) |
| `dremio-opensearch-operator` | OpenSearch cluster | `opensearch.opster.io` / `*.opensearch` |

The chart also references companion operator charts on quay, e.g.
`oci://quay.io/dremio/dremio-mongodb-operator-helm` and
`oci://quay.io/dremio/dremio-opensearch-operator-helm`. Note the values toggle
`opensearchOperator.installCRDs` (default `false`) — see B3.

## B2. Helm + CRD mechanics (always applies)

1. CRDs in a chart's `crds/` dir are installed **once, before** the release, and
   **only if absent**.
2. `helm upgrade` **does not** upgrade existing CRDs.
3. `helm uninstall` **does not** delete CRDs.
4. CRDs are cluster-scoped → **cluster-admin** to create/upgrade.

Discover what YOUR chart version ships:

```bash
V=3.2.3
helm pull oci://quay.io/dremio/dremio-helm --version "$V" --untar -d /tmp/dchart
ls -1 /tmp/dchart/*/crds/ 2>/dev/null || echo "no crds/ dir (CRDs may come via subcharts)"
grep -RinE 'installCRDs|customresourcedefinition' /tmp/dchart/*/values.yaml /tmp/dchart/*/charts 2>/dev/null | head
```

## B3. Execute — ensure CRDs are present (cluster-admin, before/with install)

- The OpenShift overrides set `opensearchOperator.installCRDs: false` by default
  (and `SKIP_INIT_CONTAINER=true`). If the OpenSearch CRDs are **not already**
  on the cluster, either flip that to `true` on a **first, admin-run** install,
  or apply the operator's CRDs out of band:

```bash
# Option A: let the operator subchart install its CRDs on first admin install
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  -n dremio-dev -f helm/values-openshift-overrides.yaml -f helm/values-common.yaml \
  -f helm/values-dev.yaml --set opensearchOperator.installCRDs=true --wait

# Option B (GitOps/air-gapped): apply CRDs explicitly, then install with --skip-crds
oc apply -f /tmp/dchart/*/crds/           # if a crds/ dir exists
helm upgrade --install dremio ... --skip-crds --wait
```

## B4. Verify CRDs Established

```bash
oc get crd | grep -iE 'dremio|opensearch|psmdb|percona'
for c in $(oc get crd -o name | grep -iE 'dremio|opensearch|psmdb'); do
  echo "$c -> $(oc get $c -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')"
done
oc explain perconaservermongodbs.psmdb.percona.com   # example
```

## B5. Operate the custom resources

```bash
NS=dremio-dev
# Operators reconcile CRs the chart created from your values:
oc get perconaservermongodbs,opensearchclusters -n "$NS" 2>/dev/null
oc describe perconaservermongodb -n "$NS"
# Operator pods + logs:
oc get pods -n "$NS" | grep -iE 'operator'
oc logs -f deploy/dremio-mongodb-operator -n "$NS" 2>/dev/null || true
```

A CR stuck reconciling usually means the **CRD is older than the operator
expects** → upgrade CRDs (B6).

## B6. Upgrade CRDs (manual — Helm won't)

```bash
V_NEW=3.3.0
helm pull oci://quay.io/dremio/dremio-helm --version "$V_NEW" --untar -d /tmp/dnew
oc diff  -f /tmp/dnew/*/crds/ || true       # review (additive = safe)
oc apply -f /tmp/dnew/*/crds/               # cluster-admin; preserves CRs
helm upgrade dremio oci://quay.io/dremio/dremio-helm --version "$V_NEW" \
  -n dremio-dev -f helm/values-openshift-overrides.yaml -f helm/values-common.yaml \
  -f helm/values-dev.yaml --skip-crds --wait
```

> ⚠️ Never `oc delete crd` on a live cluster — it **cascade-deletes every CR of
> that kind**, which for the MongoDB/OpenSearch operators tears down the catalog
> metadata store and search cluster (data loss).

## B7. CRD failure playbook

| Symptom | Cause | Fix |
|---------|-------|-----|
| `no matches for kind "PerconaServerMongoDB"` | operator CRD absent | install CRDs (B3), confirm Established (B4) |
| OpenSearch cluster never forms | CRDs missing or `vm.max_map_count` low | check CRDs + the Tuned CR (Part 0 / install Step 4) |
| New values field ignored after upgrade | Helm didn't upgrade CRD | manually `oc apply` new CRDs (B6) |
| `forbidden: cannot create customresourcedefinitions` | not cluster-admin | hand CRD apply to an admin |

## B8. Rollback / removal

```bash
helm uninstall dremio -n dremio-dev        # leaves CRDs + CRs by Helm design
oc get perconaservermongodbs,opensearchclusters -A
oc delete perconaservermongodb --all -n dremio-dev    # review first
# finally, only if no env needs them (irreversible for those kinds):
oc delete crd <name1> <name2>
```

---

# PART C — Combined ordered execution (prod, copy/paste)

```bash
set -euo pipefail
V=3.2.3; NS=dremio-prod

# 1) cluster-admin: OpenSearch node tuning
oc apply -f openshift/02-node-tuning-opensearch.yaml

# 2) cluster-admin: pre-stage CRDs (if a crds/ dir exists in the chart)
helm pull oci://quay.io/dremio/dremio-helm --version "$V" --untar -d /tmp/dchart
[ -d /tmp/dchart/*/crds ] && oc apply -f /tmp/dchart/*/crds/ || echo "CRDs via subcharts"

# 3) project: namespace + pull secret + license
oc new-project "$NS" || oc project "$NS"
oc create secret docker-registry dremio-pull-secret \
  --docker-server=quay.io --docker-username='<user>' --docker-password='<token>' -n "$NS"

# 4) verify SCC prerequisites
oc get scc nonroot nonroot-v2
oc auth can-i create rolebindings.rbac.authorization.k8s.io -n "$NS"

# 5) install (useOpenShiftRoles creates the SCC RoleBindings)
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm --version "$V" \
  -n "$NS" \
  -f helm/values-openshift-overrides.yaml \
  -f helm/values-common.yaml \
  -f helm/values-prod.yaml \
  --skip-crds --wait --timeout 30m

# 6) post-checks
oc get pods -n "$NS" -o 'custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
oc get rolebinding -n "$NS" | grep nonroot
oc get crd | grep -iE 'dremio|opensearch|psmdb'
```

---

## Accuracy note

SCC RoleBinding names and the `useOpenShiftRoles` behaviour are taken from
Dremio's official `values-openshift-overrides.yaml` and the chart's own
OpenShift-roles tests. CRD group/kind names are operator/version specific —
confirm with **B2/B4** against your pinned chart (`3.x.x`).
