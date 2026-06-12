# Uninstall & Upgrade (Dremio 26 v3 chart)

## Uninstall — keep data

Removes workloads, Services, and the chart-created RoleBindings/ServiceAccounts,
but keeps PVCs (coordinator metadata, MongoDB, OpenSearch) and the namespace:

```bash
ENV=dev ./scripts/uninstall.sh
# equivalent:
oc delete route dremio-ui dremio-flight -n dremio-dev --ignore-not-found
helm uninstall dremio -n dremio-dev
```

Helm leaves PVCs and **CRDs** behind by design. The cluster-wide Tuned CR is
shared across environments — leave it unless no Dremio env remains.

## Uninstall — delete everything (DATA LOSS)

```bash
PURGE=1 ENV=dev ./scripts/uninstall.sh
# also removes PVCs (incl. MongoDB catalog metadata + OpenSearch) and the namespace
```

CRDs are cluster-scoped and shared; remove them **only** when no Dremio install
remains anywhere (see [RUNBOOK.md](RUNBOOK.md) B8) — deleting a CRD
cascade-deletes its custom resources.

## Upgrade Dremio (chart 3.x → 3.y)

1. **Back up** the coordinator metadata PVC, the MongoDB catalog data, and the
   distributed/catalog object storage.
2. Read Dremio's upgrade notes; metadata migrations may run on first start and
   are typically **one-way**.
3. **Upgrade CRDs first** if the new chart ships changes (Helm won't):
   ```bash
   helm pull oci://quay.io/dremio/dremio-helm --version 3.3.0 --untar -d /tmp/dnew
   oc apply -f /tmp/dnew/*/crds/ 2>/dev/null || true   # cluster-admin
   ```
4. Re-run the layered upgrade with the new chart version and matching app tag:
   ```bash
   # bump dremio.image.tag in helm/values-common.yaml to the new 26.x, then:
   helm upgrade --install dremio oci://quay.io/dremio/dremio-helm \
     --version 3.3.0 \
     -n dremio-prod \
     -f helm/values-openshift-overrides.yaml \
     -f helm/values-common.yaml \
     -f helm/values-prod.yaml \
     --skip-crds --wait --timeout 30m
   ```
5. Watch the coordinator finish metadata migration:
   ```bash
   oc logs -f dremio-master-0 -n dremio-prod
   ```

> Roll forward, not back: once metadata is upgraded you generally cannot
> downgrade — hence the mandatory backup in step 1.
