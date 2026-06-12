# Troubleshooting

Work top-to-bottom: identify which layer is unhappy, then jump to the matching
section.

```bash
oc get pods -n dremio
oc get events -n dremio --sort-by=.lastTimestamp | tail -30
```

---

## Pod stuck in `Pending`

Almost always **storage** or **scheduling**.

```bash
oc describe pod <pod> -n dremio | sed -n '/Events/,$p'
oc get pvc -n dremio
```

- **`pod has unbound immediate PersistentVolumeClaims`** → no StorageClass could
  provision the volume. Check `oc get storageclass`. If there is no default
  class, set `storageClass:` explicitly in the values and re-run the upgrade.
- **`Insufficient cpu/memory`** → the cluster can’t satisfy the requests. Lower
  `cpu`/`memory` in the values, or add capacity.

---

## Pod `CrashLoopBackOff` with permission errors

Symptoms: `Permission denied` / `Operation not permitted` writing to a volume,
or pods admitted to `restricted-v2` and failing.

The SCC RoleBindings (`useOpenShiftRoles`) didn't apply.

```bash
NS=dremio-dev
# Which SCC did the pod actually get? (want nonroot / nonroot-v2)
oc get pods -n $NS -o 'custom-columns=POD:.metadata.name,SCC:.metadata.annotations.openshift\.io/scc'
# Did the chart create the RoleBindings?
oc get rolebinding -n $NS | grep nonroot
```

Fixes:
- Ensure `helm/values-openshift-overrides.yaml` was layered **first** (it sets
  `useOpenShiftRoles: true`). Re-run the install with all three `-f` files.
- Ensure the installer can create RoleBindings:
  `oc auth can-i create rolebindings -n $NS`.
- Do **not** add a custom SCC or set `serviceAccount` manually — the chart
  manages SAs and binds the built-in `nonroot`/`nonroot-v2` SCCs.

---

## OpenSearch pods crash / cluster never forms

Symptom: OpenSearch logs mention `max virtual memory areas vm.max_map_count
[65530] is too low`.

The Node Tuning Operator setting wasn't applied (the OpenShift overrides disable
the privileged init container on purpose).

```bash
oc apply -f openshift/02-node-tuning-opensearch.yaml          # cluster-admin
oc debug node/<node> -- chroot /host sysctl vm.max_map_count  # must be >= 262144
```

---

## `helm install` can’t pull the chart

```
Error: failed to download "oci://quay.io/dremio/dremio-helm"
```

- Confirm Helm is **≥ 3.8**: `helm version`.
- Test reachability: `helm show chart oci://quay.io/dremio/dremio-helm`.
- Behind a proxy/firewall? Allow egress to `quay.io`, or `helm registry login
  quay.io` if your access requires auth.
- Air-gapped? `helm pull oci://quay.io/dremio/dremio-helm --version <v>` on a
  connected box, copy the `.tgz`, and `helm install ./dremio-<v>.tgz ...`.

---

## Image pull errors (`ImagePullBackOff` / `ErrImagePull`)

```bash
oc describe pod <pod> -n dremio | grep -A3 -i 'failed to pull\|pull access'
```

- **Enterprise image** `quay.io/dremio/dremio-enterprise:<tag>` unauthorized →
  create the `dremio-pull-secret` in the namespace (install guide Step 5); it is
  referenced via `imagePullSecrets` in `values-common.yaml`.
- Tag not found → verify the exact `26.x` app tag and fix `dremio.image.tag`
  (and the companion images all come from quay — ensure egress/mirror).

---

## Can’t reach the Web UI

```bash
oc get route dremio-ui -n dremio
oc get svc -n dremio
```

- **404 / service not found from the Route** → the Route’s `to.name` doesn’t
  match the real client service name (`dremio-client`). Run `oc get svc -n
  dremio-<env>`, then edit `to.name` in `openshift/03-route-ui.yaml` and re-apply.
- **`targetPort` not found** → the service uses numeric ports, not named ones.
  Change `port.targetPort` in the Route to `9047`.
- **Just testing?** Bypass Routes entirely:
  ```bash
  oc port-forward svc/dremio-client 9047:9047 -n dremio
  ```

---

## Arrow Flight route doesn’t connect

Flight is gRPC/HTTP2 and the passthrough Route requires TLS **inside** Dremio.
Set `coordinator.flight.tls.enabled: true` (and provide certs) in the values,
re-run the upgrade, then re-apply `04-route-flight.yaml`. Without in-pod TLS the
passthrough route cannot complete the gRPC handshake.

---

## Values key “does nothing”

The v3 chart may name a key differently than this template. Always reconcile:

```bash
helm show values oci://quay.io/dremio/dremio-helm --version <v> \
  > helm/values-reference.generated.yaml
```

Then confirm the key path you’re overriding exists in that file, and move it if
not. Render what Helm *would* apply, without installing:

```bash
helm template dremio oci://quay.io/dremio/dremio-helm --version 3.2.3 \
  -f helm/values-openshift-overrides.yaml -f helm/values-common.yaml \
  -f helm/values-dev.yaml -n dremio-dev | less
```

---

## Useful one-liners

```bash
# Full picture
oc get statefulset,pods,pvc,svc,route -n dremio

# Follow the master log
oc logs -f dremio-master-0 -n dremio

# Describe what Helm released
helm get values dremio -n dremio
helm get manifest dremio -n dremio | less

# Clean reinstall (KEEP data)        / (WIPE data)
./scripts/uninstall.sh               # PURGE=1 ./scripts/uninstall.sh
```
