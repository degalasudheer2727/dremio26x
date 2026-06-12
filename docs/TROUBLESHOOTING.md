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

Symptoms in logs: `Permission denied`, `Operation not permitted`, can’t write to
`/opt/dremio/data` or the dist volume.

This means the SCC/UID is wrong.

```bash
# Is the SA actually allowed to use our SCC?
oc auth can-i use scc/dremio-scc \
  --as=system:serviceaccount:dremio:dremio -n dremio        # must say "yes"

# Which SCC did the pod actually get?
oc get pod <pod> -n dremio -o jsonpath='{.metadata.annotations.openshift\.io/scc}{"\n"}'
```

Fixes:
- Ensure `serviceAccount: dremio` is set in the values (pods must run as the
  `dremio` SA, not `default`).
- Ensure `openshift/03-scc.yaml` and `04-rbac.yaml` were applied by a
  cluster-admin.
- Make sure you did **not** set `runAsUser`/`fsGroup` in the values — let the
  SCC inject UID/GID 999.

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

- **OSS image** `dremio/dremio-oss:<tag>` not found → the tag doesn’t exist;
  verify the exact 26.x tag on the registry and fix `image.tag`.
- **Enterprise image** unauthorized → create and link the pull secret
  (install guide Step 5) and reference it in `image.pullSecrets`.

---

## Can’t reach the Web UI

```bash
oc get route dremio-ui -n dremio
oc get svc -n dremio
```

- **404 / service not found from the Route** → the Route’s `to.name` doesn’t
  match the real client service name. Run `oc get svc -n dremio`, then edit
  `to.name` in `openshift/05-route-ui.yaml` and re-apply.
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
re-run the upgrade, then re-apply `06-route-flight.yaml`. Without in-pod TLS the
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
helm template dremio oci://quay.io/dremio/dremio-helm --version <v> \
  --values helm/values-openshift-minimal.yaml -n dremio | less
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
