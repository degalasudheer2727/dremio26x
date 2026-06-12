#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - remove a Dremio 26 (v3) deployment from OpenShift
# =============================================================================
# Keeps data (PVCs) by default. The chart manages its own ServiceAccounts and
# OpenShift RoleBindings (useOpenShiftRoles), so `helm uninstall` removes those
# too — there is no custom SCC to clean up.
#
# Usage:
#   ENV=dev ./scripts/uninstall.sh            # keep data
#   PURGE=1 ENV=prod ./scripts/uninstall.sh   # delete PVCs + namespace
#
# Env vars: ENV (dev|qa|prod, default dev), DREMIO_NAMESPACE, DREMIO_RELEASE, PURGE
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${ENV:-dev}"
case "${ENV}" in dev|qa|prod) ;; *) echo "ENV must be dev|qa|prod"; exit 1;; esac
NS="${DREMIO_NAMESPACE:-dremio-${ENV}}"
RELEASE="${DREMIO_RELEASE:-dremio}"
PURGE="${PURGE:-0}"

echo ">> Removing Routes (ns: ${NS})..."
oc delete route dremio-ui dremio-flight -n "${NS}" --ignore-not-found

echo ">> Uninstalling Helm release '${RELEASE}' from ${NS}..."
helm uninstall "${RELEASE}" -n "${NS}" || echo "   (release not found)"

if [ "${PURGE}" = "1" ]; then
  echo ">> PURGE=1: deleting PVCs (DATA LOSS) and namespace..."
  oc delete pvc --all -n "${NS}" --ignore-not-found
  oc delete namespace "${NS}" --ignore-not-found
  echo ">> NOTE: the cluster-wide Tuned CR (openshift/02-node-tuning-opensearch.yaml)"
  echo ">>       is shared across environments and is left in place. Remove it"
  echo ">>       manually only if no Dremio env remains:  oc delete tuned openshift-opensearch -n openshift-cluster-node-tuning-operator"
else
  echo ">> Kept PVCs and namespace. Re-run with PURGE=1 to wipe."
  oc get pvc -n "${NS}" 2>/dev/null || true
fi
