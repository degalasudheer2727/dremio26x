#!/usr/bin/env bash
# =============================================================================
# uninstall.sh - remove a Dremio 26 deployment from OpenShift (env-aware)
# =============================================================================
# By default this removes the Helm release and Routes but KEEPS your data
# (PersistentVolumeClaims) and the namespace, so a reinstall keeps your sources,
# spaces and reflections.
#
# Usage:
#   ./scripts/uninstall.sh                 # minimal/'dremio' ns, keep data
#   ENV=dev ./scripts/uninstall.sh         # dremio-dev, keep data
#   PURGE=1 ENV=prod ./scripts/uninstall.sh# dremio-prod, DELETE everything
#
# Environment overrides:
#   ENV              dev|qa|prod (selects dremio-<ENV> namespace + -<ENV> SCC)
#   DREMIO_NAMESPACE (default: dremio, or dremio-<ENV>)
#   DREMIO_RELEASE   (default: dremio)
#   PURGE            1 = also delete PVCs, RBAC, SCC, SA and namespace
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${ENV:-}"
RELEASE="${DREMIO_RELEASE:-dremio}"
PURGE="${PURGE:-0}"
if [ -n "${ENV}" ]; then
  case "${ENV}" in dev|qa|prod) ;; *) echo "ENV must be dev|qa|prod"; exit 1;; esac
  NS="${DREMIO_NAMESPACE:-dremio-${ENV}}"; SCC="dremio-scc-${ENV}"
else
  NS="${DREMIO_NAMESPACE:-dremio}"; SCC="dremio-scc"
fi

echo ">> Removing Routes (ns: ${NS})..."
oc delete route dremio-ui dremio-flight -n "${NS}" --ignore-not-found

echo ">> Uninstalling Helm release '${RELEASE}' from ${NS}..."
helm uninstall "${RELEASE}" -n "${NS}" || echo "   (release not found)"

if [ "${PURGE}" = "1" ]; then
  echo ">> PURGE=1: deleting PVCs (DATA LOSS), RBAC, SCC, SA and namespace..."
  oc delete pvc --all -n "${NS}" --ignore-not-found
  oc delete rolebinding dremio-use-scc role dremio-use-scc -n "${NS}" --ignore-not-found
  oc delete scc "${SCC}" --ignore-not-found
  oc delete sa dremio -n "${NS}" --ignore-not-found
  oc delete namespace "${NS}" --ignore-not-found
  echo ">> Full purge complete."
else
  echo ">> Kept PVCs and namespace. To wipe everything, re-run with PURGE=1."
  oc get pvc -n "${NS}" 2>/dev/null || true
fi
