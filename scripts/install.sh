#!/usr/bin/env bash
# =============================================================================
# install.sh - deploy Dremio 26 (v3 chart) to OpenShift, per Dremio's guide
# =============================================================================
# Follows Dremio's official OpenShift method: helm OCI chart + the two-file
# overrides pattern (values-openshift-overrides.yaml FIRST), with useOpenShiftRoles
# so the CHART creates the SCC RoleBindings (nonroot/nonroot-v2). See
# docs/00-INSTALL-OPENSHIFT.md and docs/RUNBOOK.md.
#
# Usage:
#   ENV=dev  ./scripts/install.sh
#   ENV=qa   ./scripts/install.sh
#   ENV=prod CHART_VERSION=3.2.3 ./scripts/install.sh
#
# Env vars:
#   ENV                 dev|qa|prod              (default: dev)
#   DREMIO_NAMESPACE    (default: dremio-<ENV>)
#   DREMIO_RELEASE      (default: dremio)
#   DREMIO_CHART        (default: oci://quay.io/dremio/dremio-helm)
#   CHART_VERSION       Helm CHART semver, e.g. 3.2.3 (NOT the 26.x app version)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."

ENV="${ENV:-dev}"
case "${ENV}" in dev|qa|prod) ;; *) echo "ENV must be dev|qa|prod"; exit 1;; esac
NS="${DREMIO_NAMESPACE:-dremio-${ENV}}"
RELEASE="${DREMIO_RELEASE:-dremio}"
CHART="${DREMIO_CHART:-oci://quay.io/dremio/dremio-helm}"
VER_ARG=(); [ -n "${CHART_VERSION:-}" ] && VER_ARG=(--version "${CHART_VERSION}")

# Official two-file overrides + our per-env layer (order matters: OpenShift first).
VALUES=( -f helm/values-openshift-overrides.yaml
         -f helm/values-common.yaml
         -f "helm/values-${ENV}.yaml" )

echo ">> Environment: ${ENV}   namespace: ${NS}   chart: ${CHART} ${CHART_VERSION:-(latest)}"

echo ">> [1/6] Namespace..."
oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -

echo ">> [2/6] OpenSearch node tuning (vm.max_map_count) — cluster-admin..."
# Required because the OpenShift overrides disable the privileged init container.
oc apply -f openshift/02-node-tuning-opensearch.yaml \
  || echo "   (could not apply Tuned CR — ask a cluster-admin; see RUNBOOK Part B)"

echo ">> [3/6] Checking for the Enterprise image pull secret..."
if ! oc get secret dremio-pull-secret -n "${NS}" >/dev/null 2>&1; then
  cat <<EOF
   !! Secret 'dremio-pull-secret' not found in ${NS}.
      The chart defaults to the Enterprise image on quay.io. Create it:
        oc create secret docker-registry dremio-pull-secret \\
          --docker-server=quay.io --docker-username='<user>' \\
          --docker-password='<token>' -n ${NS}
      (and set your license in helm/values-common.yaml). Continuing anyway...
EOF
fi

echo ">> [4/6] (Reference) generating the chart's real default values..."
helm show values "${CHART}" "${VER_ARG[@]}" > helm/values-reference.generated.yaml 2>/dev/null \
  && echo "   wrote helm/values-reference.generated.yaml" \
  || echo "   (skipped: could not pull chart — check quay.io / 'helm registry login quay.io')"

echo ">> [5/6] Dry-run validate, then install..."
helm upgrade --install "${RELEASE}" "${CHART}" "${VER_ARG[@]}" \
  --namespace "${NS}" "${VALUES[@]}" --dry-run >/dev/null && echo "   dry-run OK"
helm upgrade --install "${RELEASE}" "${CHART}" "${VER_ARG[@]}" \
  --namespace "${NS}" "${VALUES[@]}" --wait --timeout 30m

echo ">> [6/6] Pods + Web UI Route..."
oc get pods -n "${NS}"
sed "s|namespace: dremio$|namespace: ${NS}|g" openshift/03-route-ui.yaml | oc apply -f -
HOST=$(oc get route dremio-ui -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo
echo "============================================================"
echo " Dremio install complete  (env: ${ENV}, ns: ${NS})"
[ -n "${HOST}" ] && echo " Web UI:  https://${HOST}" || echo " Route not found - check 'oc get route -n ${NS}'."
echo " First login: open the URL and create the admin account."
echo "============================================================"
