# Uninstall & Upgrade

## Uninstall — keep my data

Removes the running workloads and Routes but **keeps PersistentVolumeClaims**
and the namespace, so a later reinstall keeps your sources, spaces, and
reflections:

```bash
./scripts/uninstall.sh
```

Equivalent manual steps:

```bash
oc delete -f openshift/05-route-ui.yaml --ignore-not-found
oc delete -f openshift/06-route-flight.yaml --ignore-not-found
helm uninstall dremio -n dremio
```

> `helm uninstall` deletes the StatefulSets but, by design, leaves the PVCs that
> StatefulSets created. Your data survives.

## Uninstall — delete everything (DATA LOSS)

Also deletes PVCs, RBAC, the SCC, the ServiceAccount and the namespace:

```bash
PURGE=1 ./scripts/uninstall.sh
```

Equivalent manual steps:

```bash
helm uninstall dremio -n dremio
oc delete pvc --all -n dremio            # irreversible
oc delete -f openshift/04-rbac.yaml --ignore-not-found
oc delete -f openshift/03-scc.yaml --ignore-not-found   # needs cluster-admin
oc delete -f openshift/02-serviceaccount.yaml --ignore-not-found
oc delete -f openshift/01-namespace.yaml --ignore-not-found
```

## Upgrade Dremio (e.g. 26.0.0 → 26.x.y)

1. **Back up** the coordinator metadata PVC and your distributed storage first.
2. Read Dremio’s official upgrade notes for the target version (metadata
   migrations may run on first start and can be one-way).
3. Bump **both** the image tag and the chart version, then re-run the same
   idempotent command you used to install:

```bash
# edit helm/values-openshift-minimal.yaml -> image.tag: "26.x.y"

helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
  --version 26.x.y \
  --namespace dremio \
  --values helm/values-openshift-minimal.yaml \
  --wait --timeout 20m
```

4. Watch the master come up and confirm metadata migration completed:

```bash
oc logs -f dremio-master-0 -n dremio
```

> Roll forward, not back: once the coordinator upgrades its metadata store you
> generally **cannot** downgrade. That is why step 1 (backup) is mandatory.
