#!/usr/bin/env bash
# =============================================================================
# install.sh - deploy Dremio 26 (minimal) to OpenShift
# =============================================================================
# This is a convenience wrapper around the exact same steps documented in
# docs/00-INSTALL-OPENSHIFT.md. Read that guide at least once before trusting
# automation.
#
# Usage:
#   ./scripts/install.sh                 # uses defaults below
#   DREMIO_CHART_VERSION=26.0.0 ./scripts/install.sh
#
# Environment overrides:
#   DREMIO_NAMESPACE       (default: dremio)
#   DREMIO_RELEASE         (default: dremio)
#   DREMIO_CHART           (default: oci://quay.io/dremio/dremio-helm)
#   DREMIO_CHART_VERSION   (default: unset -> latest; STRONGLY recommend pinning)
#   DREMIO_VALUES          (default: helm/values-openshift-minimal.yaml)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

NS="${DREMIO_NAMESPACE:-dremio}"
RELEASE="${DREMIO_RELEASE:-dremio}"
CHART="${DREMIO_CHART:-oci://quay.io/dremio/dremio-helm}"
VALUES="${DREMIO_VALUES:-helm/values-openshift-minimal.yaml}"
VERSION_ARG=()
[ -n "${DREMIO_CHART_VERSION:-}" ] && VERSION_ARG=(--version "${DREMIO_CHART_VERSION}")

echo ">> [1/6] Creating project, ServiceAccount, SCC and RBAC..."
oc apply -f openshift/01-namespace.yaml
oc apply -f openshift/02-serviceaccount.yaml
# SCC + RBAC need cluster-admin. If this fails, ask an admin to apply these two.
oc apply -f openshift/03-scc.yaml
oc apply -f openshift/04-rbac.yaml

echo ">> [2/6] (Reference) generating the chart's real default values for diffing..."
helm show values "${CHART}" "${VERSION_ARG[@]}" > helm/values-reference.generated.yaml 2>/dev/null \
  && echo "   wrote helm/values-reference.generated.yaml" \
  || echo "   (skipped: could not pull chart values - check registry access)"

echo ">> [3/6] Validating the install with a dry-run / template render..."
helm upgrade --install "${RELEASE}" "${CHART}" "${VERSION_ARG[@]}" \
  --namespace "${NS}" \
  --values "${VALUES}" \
  --dry-run >/dev/null
echo "   dry-run OK"

echo ">> [4/6] Installing Dremio (this creates the StatefulSets)..."
helm upgrade --install "${RELEASE}" "${CHART}" "${VERSION_ARG[@]}" \
  --namespace "${NS}" \
  --values "${VALUES}" \
  --wait --timeout 15m

echo ">> [5/6] Waiting for pods to become Ready..."
oc rollout status statefulset -n "${NS}" --timeout=600s || true
oc get pods -n "${NS}"

echo ">> [6/6] Exposing the Web UI via an OpenShift Route..."
# Auto-detect the client service name; fall back to dremio-client.
SVC=$(oc get svc -n "${NS}" -o name 2>/dev/null | grep -E 'client|coordinator' | head -n1 | sed 's#service/##' || true)
SVC="${SVC:-dremio-client}"
sed "s/name: dremio-client/name: ${SVC}/" openshift/05-route-ui.yaml | oc apply -f -

HOST=$(oc get route dremio-ui -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo
echo "============================================================"
echo " Dremio install complete."
[ -n "${HOST}" ] && echo " Web UI:  https://${HOST}" || echo " Web UI route not found - check 'oc get route -n ${NS}'."
echo " First-time login: open the URL and create the admin account."
echo "============================================================"
