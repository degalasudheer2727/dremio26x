#!/usr/bin/env bash
# =============================================================================
# install.sh - deploy Dremio 26 to OpenShift (dev / qa / prod aware)
# =============================================================================
# Convenience wrapper around the steps in docs/00-INSTALL-OPENSHIFT.md and the
# environment design in docs/ENVIRONMENTS.md. Read those before trusting it.
#
# Usage:
#   ./scripts/install.sh                       # ENV unset -> single 'dremio' ns, minimal values
#   ENV=dev  ./scripts/install.sh              # namespace dremio-dev,  common + dev overlay
#   ENV=qa   ./scripts/install.sh              # namespace dremio-qa,   common + qa overlay
#   ENV=prod DREMIO_CHART_VERSION=26.0.0 ./scripts/install.sh
#
# Environment overrides:
#   ENV                    dev|qa|prod (selects layered values + default namespace)
#   DREMIO_NAMESPACE       (default: dremio, or dremio-<ENV> when ENV is set)
#   DREMIO_RELEASE         (default: dremio)
#   DREMIO_CHART           (default: oci://quay.io/dremio/dremio-helm)
#   DREMIO_CHART_VERSION   (default: unset -> latest; STRONGLY recommend pinning)
#   DREMIO_VALUES          (override the values file list entirely, space-separated)
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."   # repo root

ENV="${ENV:-}"
RELEASE="${DREMIO_RELEASE:-dremio}"
CHART="${DREMIO_CHART:-oci://quay.io/dremio/dremio-helm}"
VERSION_ARG=()
[ -n "${DREMIO_CHART_VERSION:-}" ] && VERSION_ARG=(--version "${DREMIO_CHART_VERSION}")

# --- Resolve namespace + values files for the chosen environment -------------
if [ -n "${ENV}" ]; then
  case "${ENV}" in dev|qa|prod) ;; *) echo "ENV must be dev|qa|prod"; exit 1;; esac
  NS="${DREMIO_NAMESPACE:-dremio-${ENV}}"
  DEFAULT_VALUES="helm/values-common.yaml helm/values-${ENV}.yaml"
else
  NS="${DREMIO_NAMESPACE:-dremio}"
  DEFAULT_VALUES="helm/values-openshift-minimal.yaml"
fi
read -r -a VALUES_FILES <<< "${DREMIO_VALUES:-$DEFAULT_VALUES}"
VALUES_ARGS=(); for f in "${VALUES_FILES[@]}"; do VALUES_ARGS+=(--values "$f"); done

# --- Apply an OpenShift manifest, rewriting namespace/SCC names per-env -------
# When ENV is set we isolate each environment: namespace -> $NS, the SCC and its
# bindings get an -${ENV} suffix, and ServiceAccount references point at $NS.
kapply() {
  local file="$1"
  if [ -z "${ENV}" ]; then oc apply -f "${file}"; return; fi
  sed -e "s|namespace: dremio$|namespace: ${NS}|g" \
      -e "s|system:serviceaccount:dremio:dremio|system:serviceaccount:${NS}:dremio|g" \
      -e "s|dremio-scc|dremio-scc-${ENV}|g" \
      "${file}" | oc apply -f -
}

echo ">> Target environment: ${ENV:-<minimal>}   namespace: ${NS}"
echo ">> Values: ${VALUES_FILES[*]}"

echo ">> [1/6] Creating project, ServiceAccount, SCC and RBAC..."
if [ -n "${ENV}" ]; then
  oc create namespace "${NS}" --dry-run=client -o yaml | oc apply -f -
else
  oc apply -f openshift/01-namespace.yaml
fi
kapply openshift/02-serviceaccount.yaml
# SCC + RBAC need cluster-admin. If this fails, ask an admin to apply these two.
kapply openshift/03-scc.yaml
kapply openshift/04-rbac.yaml

echo ">> [2/6] (Reference) generating the chart's real default values for diffing..."
helm show values "${CHART}" "${VERSION_ARG[@]}" > helm/values-reference.generated.yaml 2>/dev/null \
  && echo "   wrote helm/values-reference.generated.yaml" \
  || echo "   (skipped: could not pull chart values - check registry access)"

echo ">> [3/6] Validating the install with a dry-run / template render..."
helm upgrade --install "${RELEASE}" "${CHART}" "${VERSION_ARG[@]}" \
  --namespace "${NS}" "${VALUES_ARGS[@]}" --dry-run >/dev/null
echo "   dry-run OK"

echo ">> [4/6] Installing Dremio (this creates the StatefulSets)..."
helm upgrade --install "${RELEASE}" "${CHART}" "${VERSION_ARG[@]}" \
  --namespace "${NS}" "${VALUES_ARGS[@]}" --wait --timeout 20m

echo ">> [5/6] Waiting for pods to become Ready..."
oc rollout status statefulset -n "${NS}" --timeout=900s || true
oc get pods -n "${NS}"

echo ">> [6/6] Exposing the Web UI via an OpenShift Route..."
SVC=$(oc get svc -n "${NS}" -o name 2>/dev/null | grep -E 'client|coordinator' | head -n1 | sed 's#service/##' || true)
SVC="${SVC:-dremio-client}"
sed -e "s/name: dremio-client/name: ${SVC}/" -e "s|namespace: dremio$|namespace: ${NS}|g" \
  openshift/05-route-ui.yaml | oc apply -f -

HOST=$(oc get route dremio-ui -n "${NS}" -o jsonpath='{.spec.host}' 2>/dev/null || true)
echo
echo "============================================================"
echo " Dremio install complete  (env: ${ENV:-minimal}, ns: ${NS})"
[ -n "${HOST}" ] && echo " Web UI:  https://${HOST}" || echo " Web UI route not found - check 'oc get route -n ${NS}'."
echo " First-time login: open the URL and create the admin account."
echo "============================================================"
