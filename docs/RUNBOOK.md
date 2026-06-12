# Operational Runbook — SCC & CRD Execution

A step-by-step operations runbook for the **cluster-admin-level** parts of a
Dremio 26 / OpenShift install: the **SecurityContextConstraint (SCC)** and any
**CustomResourceDefinitions (CRDs)** the v3 chart ships. These are the steps a
project member usually *cannot* do and must hand to a cluster-admin, so they are
documented here in isolation with verification and rollback for each.

> Scope: cluster-scoped objects (SCC, CRDs) + their bindings. For the full
> install flow see [00-INSTALL-OPENSHIFT.md](00-INSTALL-OPENSHIFT.md); for the
> per-environment design see [ENVIRONMENTS.md](ENVIRONMENTS.md).

---

## 0. Roles & ordering (read first)

| Step | Object | Scope | Who | When |
|------|--------|-------|-----|------|
| 1 | CRDs (if any) | cluster | cluster-admin | **before** `helm install` |
| 2 | Namespace | cluster | project-admin | before SA |
| 3 | ServiceAccount | namespaced | project-admin | before SCC binding |
| 4 | SCC | cluster | cluster-admin | before pods start |
| 5 | Role/RoleBinding (SCC `use`) | namespaced | project-admin | before pods start |
| 6 | `helm install` (StatefulSets, Services) | namespaced | project-admin | last |

**Golden rule:** cluster-scoped, admin-owned objects (CRDs, SCC) go in **first**;
the Helm release goes in **last**. Tear down in the reverse order.

---

# PART A — SCC Execution Runbook

## A1. What this SCC does and why it's required

The Dremio container image runs as a **fixed user, UID/GID 999**. OpenShift's
default `restricted-v2` SCC injects a *random* UID and forbids a container
choosing its own, which breaks Dremio because every component (coordinator,
executors, ZooKeeper) must share one UID to read each other's files on the
shared volumes.

`openshift/03-scc.yaml` is a **least-privilege** exception:
- `runAsUser: MustRunAs uid 999`, `fsGroup: MustRunAs 999`
- no host network/IPC/PID, no privilege escalation, **all capabilities dropped**
- usable **only** by the `dremio` ServiceAccount in the target namespace

It is **not** the cluster-wide `anyuid` SCC.

## A2. Pre-execution checks (read-only)

```bash
oc whoami                                            # confirm you're the admin
oc auth can-i create securitycontextconstraints      # must say: yes
oc get scc dremio-scc 2>/dev/null && echo "EXISTS - this is an update" || echo "new"
```

## A3. Execute — single (minimal) namespace

```bash
# 1) namespace + ServiceAccount (project-admin is fine here)
oc apply -f openshift/01-namespace.yaml
oc apply -f openshift/02-serviceaccount.yaml

# 2) the SCC + RBAC binding (cluster-admin)
oc apply -f openshift/03-scc.yaml
oc apply -f openshift/04-rbac.yaml
```

## A3b. Execute — per environment (dev/qa/prod isolated)

Each environment gets its **own** SCC (`dremio-scc-<env>`) bound to the
`dremio` SA in its own namespace, so environments never share a security grant.
The install script does this rewrite for you:

```bash
ENV=prod ./scripts/install.sh      # applies dremio-scc-prod for ns dremio-prod
```

To do it by hand for one environment (example: prod):

```bash
NS=dremio-prod; ENVV=prod
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
sed "s|namespace: dremio$|namespace: $NS|g" openshift/02-serviceaccount.yaml | oc apply -f -
sed -e "s|system:serviceaccount:dremio:dremio|system:serviceaccount:$NS:dremio|g" \
    -e "s|dremio-scc|dremio-scc-$ENVV|g" openshift/03-scc.yaml | oc apply -f -
sed -e "s|namespace: dremio$|namespace: $NS|g" -e "s|dremio-scc|dremio-scc-$ENVV|g" \
    openshift/04-rbac.yaml | oc apply -f -
```

## A4. Verify (must all pass before installing Dremio)

```bash
# SCC exists with the expected UID pin
oc get scc dremio-scc -o jsonpath='{.runAsUser}{"\n"}'      # -> {"type":"MustRunAs","uid":999}

# The SA is actually allowed to USE the SCC
oc auth can-i use scc/dremio-scc \
   --as=system:serviceaccount:dremio:dremio -n dremio        # -> yes

# (per-env) substitute the suffixed name + namespace
oc auth can-i use scc/dremio-scc-prod \
   --as=system:serviceaccount:dremio-prod:dremio -n dremio-prod
```

After pods are running, confirm each pod was actually admitted under our SCC
(not `restricted-v2`):

```bash
oc get pods -n dremio -o \
  'custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
# every Dremio pod should show: dremio-scc (or dremio-scc-<env>)
```

## A5. SCC failure playbook

| Symptom | Cause | Fix |
|---------|-------|-----|
| Pod `CrashLoopBackOff`, logs `Permission denied` writing `/opt/dremio/data` | pod got `restricted-v2`, not our SCC | confirm `serviceAccount: dremio` in values; re-run A4 verify; ensure RoleBinding applied |
| `oc auth can-i use scc/...` → **no** | RBAC not applied / wrong namespace | re-apply `04-rbac.yaml` for the right namespace |
| `Error: securitycontextconstraints ... forbidden` on apply | you are not cluster-admin | hand `03-scc.yaml`+`04-rbac.yaml` to an admin |
| Pod admitted to `restricted-v2` even though SCC exists | another SCC out-ranks ours / SA mismatch | check `oc get pod <p> -o yaml \| grep scc`; ensure no broader SCC is also bound and that pods use the `dremio` SA |

> **Which SCC wins?** OpenShift sorts the SCCs available to a pod's SA by
> restrictiveness and picks the one that requires the least. Because our SCC is
> bound *only* to the `dremio` SA, the safest setup is to run Dremio pods under
> that SA and avoid binding `anyuid`/`privileged` to it.

## A6. Rollback / removal

```bash
# remove the binding first, then the SCC (cluster-admin)
oc delete -f openshift/04-rbac.yaml --ignore-not-found
oc delete scc dremio-scc --ignore-not-found
# per-env:
oc delete scc dremio-scc-prod --ignore-not-found
```

Removing the SCC while Dremio still runs does **not** kill running pods, but the
**next** pod (re)start will fail admission. Remove the SCC only after the Helm
release is uninstalled.

---

# PART B — CRD Execution Runbook

## B1. Background: how Helm handles CRDs (important)

Helm treats CRDs specially, and this trips people up:

1. CRDs placed in a chart's `crds/` directory are installed **once, before** the
   rest of the release, and **only if they don't already exist**.
2. **`helm upgrade` does NOT upgrade or modify existing CRDs.** New fields in a
   newer chart's CRD schema will **not** appear until you update the CRD
   **manually**.
3. **`helm uninstall` does NOT delete CRDs.** They are intentionally left behind
   so you don't lose custom resources by accident.
4. CRDs are **cluster-scoped** → creating/updating them needs **cluster-admin**.

These rules apply to the Dremio v3 chart exactly as to any chart.

> Some chart versions also bundle CRDs as *templates* (gated behind a value like
> `installCRDs`) rather than in `crds/`. Discovery below tells you which.

## B2. Discover whether the v3 chart ships CRDs

You cannot assume — check your exact chart version:

```bash
V=26.0.0
# Pull and unpack the chart locally
helm pull oci://quay.io/dremio/dremio-helm --version "$V" --untar -d /tmp/dremio-chart

# (a) CRDs shipped in the conventional crds/ directory:
ls -1 /tmp/dremio-chart/*/crds/ 2>/dev/null || echo "no crds/ directory"

# (b) CRDs rendered as templates (search the rendered output):
helm template dremio /tmp/dremio-chart/* \
  -f helm/values-common.yaml -f helm/values-prod.yaml -n dremio-prod \
  | awk '/^kind: CustomResourceDefinition$/{f=1} f' | grep -E '^kind:|name:' | head

# (c) Any value that toggles CRD install:
grep -iE 'crd|installCRD' /tmp/dremio-chart/*/values.yaml || echo "no CRD toggle in values"
```

Record the CRD names you find (e.g. anything under `*.dremio.com`). If **none**
are found, the v3 chart for your version is CRD-less and Part B is a no-op —
skip to Part C.

## B3. Execute — install/apply CRDs (cluster-admin, BEFORE helm install)

**Option 1 — let Helm install `crds/` automatically (default).** Just run the
normal `helm install`; Helm applies the `crds/` directory first. Do nothing
extra. (You can opt out with `--skip-crds`.)

**Option 2 — apply CRDs explicitly first (recommended for GitOps/air-gapped),**
so CRD lifecycle is decoupled from the release:

```bash
# from the unpacked chart in B2
oc apply -f /tmp/dremio-chart/*/crds/        # cluster-admin

# then install the release while telling Helm not to touch CRDs again
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm --version "$V" \
  --namespace dremio-prod \
  -f helm/values-common.yaml -f helm/values-prod.yaml \
  --skip-crds
```

If CRDs are template-gated, enable them on a **first** admin-run, then disable on
subsequent project-level upgrades:

```bash
helm upgrade --install dremio ... --set installCRDs=true     # first time, admin
```

## B4. Verify CRDs are Established

```bash
# List Dremio-related CRDs (adjust the group filter to what B2 found)
oc get crd | grep -i dremio

# Each must report Established=True before creating custom resources
for c in $(oc get crd -o name | grep -i dremio); do
  echo "$c -> $(oc get $c -o jsonpath='{.status.conditions[?(@.type=="Established")].status}')"
done

# Inspect a CRD's served versions / schema
oc explain <kind>.<group>            # e.g. oc explain dremiocluster.dremio.com
oc get crd <name> -o jsonpath='{.spec.versions[*].name}{"\n"}'
```

## B5. Operating the custom resources (if the chart is operator-style)

If the chart installs an operator + CRDs, the chart's templates create the
custom resources (CRs) for you from the values file. To inspect them:

```bash
oc get <kind> -n dremio-prod                 # e.g. oc get dremiocluster -n dremio-prod
oc describe <kind> <name> -n dremio-prod     # status/conditions written by the operator
oc get <kind> <name> -n dremio-prod -o yaml  # full spec the operator reconciles

# operator logs (find the operator/controller pod)
oc get pods -n dremio-prod | grep -iE 'operator|controller'
oc logs -f <operator-pod> -n dremio-prod
```

> A CR stuck "not reconciling" almost always means the **CRD schema is older
> than the operator expects** — see B6 (Helm never auto-upgrades CRDs).

## B6. Upgrade CRDs (manual — Helm will NOT do this)

When you bump the chart version, update CRDs yourself **before** the
`helm upgrade`:

```bash
V_NEW=26.1.0
helm pull oci://quay.io/dremio/dremio-helm --version "$V_NEW" --untar -d /tmp/dremio-new

# Review what changes (additive changes are safe; removed/renamed fields are not)
oc diff -f /tmp/dremio-new/*/crds/ || true

# Apply the new CRD schema (cluster-admin). Use apply (not replace) to preserve
# existing custom resources.
oc apply -f /tmp/dremio-new/*/crds/

# THEN upgrade the release
helm upgrade dremio oci://quay.io/dremio/dremio-helm --version "$V_NEW" \
  --namespace dremio-prod \
  -f helm/values-common.yaml -f helm/values-prod.yaml --skip-crds
```

> ⚠️ Never `oc replace` or `oc delete` a CRD to "fix" a schema on a live cluster —
> deleting a CRD **cascade-deletes every custom resource of that kind**, which
> for an operator-managed Dremio can tear down the whole deployment.

## B7. CRD failure playbook

| Symptom | Cause | Fix |
|---------|-------|-----|
| `no matches for kind "<Kind>" in version "<group>/<v>"` during install | CRD not present yet | apply CRDs first (B3), confirm Established (B4) |
| New values field ignored after a chart upgrade | Helm didn't upgrade the CRD | manually `oc apply` the new CRDs (B6) |
| `forbidden: User cannot create ... customresourcedefinitions` | not cluster-admin | hand CRD apply to an admin |
| CR exists but nothing happens | operator not running / RBAC | check operator pod + logs (B5) |
| CRDs vanished workloads after `oc delete crd` | cascade delete of CRs | restore from backup; never delete CRDs on a live cluster |

## B8. Rollback / removal (last, and only when intended)

```bash
# 1) uninstall the release (leaves CRDs + CRs behind by Helm design)
helm uninstall dremio -n dremio-prod
# 2) delete remaining custom resources explicitly (review first!)
oc get <kind> -A
oc delete <kind> --all -n dremio-prod
# 3) finally remove the CRDs (cluster-admin) — irreversible for those kinds
oc delete crd <name1> <name2>
```

---

# PART C — Combined ordered execution (copy/paste)

Production example (`dremio-prod`), CRDs handled explicitly:

```bash
set -euo pipefail
V=26.0.0; NS=dremio-prod; ENVV=prod

# --- cluster-admin: CRDs first (if B2 found any) ----------------------------
helm pull oci://quay.io/dremio/dremio-helm --version "$V" --untar -d /tmp/dchart
[ -d /tmp/dchart/*/crds ] && oc apply -f /tmp/dchart/*/crds/ || echo "no CRDs to apply"

# --- namespace + ServiceAccount ---------------------------------------------
oc create namespace "$NS" --dry-run=client -o yaml | oc apply -f -
sed "s|namespace: dremio$|namespace: $NS|g" openshift/02-serviceaccount.yaml | oc apply -f -

# --- cluster-admin: SCC + RBAC ----------------------------------------------
sed -e "s|system:serviceaccount:dremio:dremio|system:serviceaccount:$NS:dremio|g" \
    -e "s|dremio-scc|dremio-scc-$ENVV|g" openshift/03-scc.yaml | oc apply -f -
sed -e "s|namespace: dremio$|namespace: $NS|g" -e "s|dremio-scc|dremio-scc-$ENVV|g" \
    openshift/04-rbac.yaml | oc apply -f -

# --- verify gate (must pass) -------------------------------------------------
oc auth can-i use scc/dremio-scc-$ENVV --as=system:serviceaccount:$NS:dremio -n $NS

# --- project-admin: install the release -------------------------------------
helm upgrade --install dremio oci://quay.io/dremio/dremio-helm --version "$V" \
  --namespace "$NS" \
  -f helm/values-common.yaml -f helm/values-prod.yaml \
  --skip-crds --wait --timeout 30m

# --- post-checks -------------------------------------------------------------
oc get pods -n $NS -o 'custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
oc get crd | grep -i dremio || true
```

> The `./scripts/install.sh` wrapper performs the namespace/SA/SCC/RBAC and
> release steps automatically (it does not pre-apply CRDs — Helm installs any
> `crds/` for you). Use the explicit sequence above when you need CRD lifecycle
> decoupled from the release (GitOps, air-gapped, or strict admin separation).

---

## Accuracy note

Whether the Dremio v3 chart ships CRDs (and their exact group/kind names) is
version-specific and must be confirmed with **B2** against your pinned chart.
The Helm CRD *mechanics* in B1/B6 are general and always apply. The SCC content
is fixed by this repo (`openshift/03-scc.yaml`) and bound via
`openshift/04-rbac.yaml`.
