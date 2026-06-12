#!/usr/bin/env bash
# =============================================================================
# preflight.sh - verify your workstation & cluster are ready for Dremio 26
# =============================================================================
# Run this BEFORE install.sh. It only READS; it changes nothing.
#
#   ./scripts/preflight.sh
# =============================================================================
set -euo pipefail

NS="${DREMIO_NAMESPACE:-dremio}"
CHART="${DREMIO_CHART:-oci://quay.io/dremio/dremio-helm}"

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
err()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }

echo "== Dremio 26 OpenShift preflight =="

echo "-- Required CLI tools --"
for bin in oc helm; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin found: $("$bin" version 2>/dev/null | head -n1)"
  else
    err "$bin NOT found in PATH"; MISSING=1
  fi
done
[ "${MISSING:-0}" = "1" ] && { err "Install the missing tools and re-run."; exit 1; }

echo "-- Helm version (need v3.8+ for OCI charts) --"
HELM_MAJOR=$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//' | cut -d. -f1 || echo 0)
HELM_MINOR=$(helm version --template '{{.Version}}' 2>/dev/null | sed 's/^v//' | cut -d. -f2 || echo 0)
if [ "${HELM_MAJOR}" -gt 3 ] || { [ "${HELM_MAJOR}" -eq 3 ] && [ "${HELM_MINOR}" -ge 8 ]; }; then
  ok "Helm supports OCI registries"
else
  err "Helm v3.8+ required for 'oci://' charts"; exit 1
fi

echo "-- Logged into an OpenShift cluster? --"
if oc whoami >/dev/null 2>&1; then
  ok "Logged in as: $(oc whoami)  @  $(oc whoami --show-server)"
else
  err "Not logged in. Run: oc login <api-url> -u <user>"; exit 1
fi

echo "-- Can create the OpenSearch node-tuning Tuned CR (cluster-admin)? --"
if oc auth can-i create tuneds.tuned.openshift.io -n openshift-cluster-node-tuning-operator >/dev/null 2>&1; then
  ok "You can create Tuned CRs (vm.max_map_count for OpenSearch)"
else
  warn "May not be able to apply openshift/02-node-tuning-opensearch.yaml. Ask a cluster-admin."
fi

echo "-- Can create RoleBindings (chart needs this for useOpenShiftRoles)? --"
if oc auth can-i create rolebindings.rbac.authorization.k8s.io -n "${NS}" >/dev/null 2>&1; then
  ok "RoleBindings allowed (chart will bind SAs to nonroot/nonroot-v2 SCCs)"
else
  warn "Cannot create RoleBindings in ${NS}; useOpenShiftRoles will fail. Need elevated rights."
fi

echo "-- Enterprise image pull secret present in '${NS}'? --"
if oc get secret dremio-pull-secret -n "${NS}" >/dev/null 2>&1; then
  ok "dremio-pull-secret found"
else
  warn "dremio-pull-secret missing in ${NS}. Create it before install (Enterprise image on quay.io)."
fi

echo "-- StorageClasses available --"
if oc get storageclass >/dev/null 2>&1; then
  oc get storageclass --no-headers 2>/dev/null | awk '{print "  - "$1}' || true
  DEFAULT_SC=$(oc get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{"\n"}{end}' 2>/dev/null || true)
  if [ -n "${DEFAULT_SC}" ]; then ok "Default StorageClass: ${DEFAULT_SC}"; else warn "No default StorageClass - set 'storageClass' in the values file."; fi
else
  warn "Could not list StorageClasses."
fi

echo "-- Can Helm reach the chart registry (${CHART})? --"
if helm show chart "${CHART}" >/dev/null 2>&1; then
  ok "Chart is reachable"
else
  warn "Could not pull ${CHART}. Check network/proxy access to quay.io and 'helm registry login quay.io' if required."
fi

echo "-- Namespace '${NS}' state --"
if oc get namespace "${NS}" >/dev/null 2>&1; then
  warn "Namespace '${NS}' already exists (install will reuse it)."
else
  ok "Namespace '${NS}' does not exist yet (will be created)."
fi

echo "== Preflight complete =="
