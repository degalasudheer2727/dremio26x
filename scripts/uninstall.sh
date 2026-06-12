#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - remove the Dremio 26 deployment from OpenShift
# =============================================================================
# By default this removes the Helm release and Routes but KEEPS your data
# (PersistentVolumeClaims) and the namespace, so a reinstall keeps your sources,
# spaces and reflections.
#
# Usage:
#   ./scripts/uninstall.sh             # keep PVCs + namespace
#   PURGE=1 ./scripts/uninstall.sh     # ALSO delete PVCs, SCC, SA and namespace
#
# Environment overrides:
#   DREMIO_NAMESPACE (default: dremio)
#   DREMIO_RELEASE   (default: dremio)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

NS="${DREMIO_NAMESPACE:-dremio}"
RELEASE="${DREMIO_RELEASE:-dremio}"
PURGE="${PURGE:-0}"

echo ">> Removing Routes..."
oc delete -f openshift/05-route-ui.yaml --ignore-not-found
oc delete -f openshift/06-route-flight.yaml --ignore-not-found

echo ">> Uninstalling Helm release '${RELEASE}'..."
helm uninstall "${RELEASE}" -n "${NS}" || echo "   (release not found)"

if [ "${PURGE}" = "1" ]; then
  echo ">> PURGE=1: deleting PVCs (DATA LOSS), RBAC, SCC, ServiceAccount and namespace..."
  oc delete pvc --all -n "${NS}" --ignore-not-found
  oc delete -f openshift/04-rbac.yaml --ignore-not-found
  oc delete -f openshift/03-scc.yaml --ignore-not-found
  oc delete -f openshift/02-serviceaccount.yaml --ignore-not-found
  oc delete -f openshift/01-namespace.yaml --ignore-not-found
  echo ">> Full purge complete."
else
  echo ">> Kept PVCs and namespace. To wipe everything, re-run with PURGE=1."
  echo "   Remaining PVCs:"
  oc get pvc -n "${NS}" 2>/dev/null || true
fi
