# =============================================================================
# Dremio 26 on OpenShift — convenience targets
# =============================================================================
# Override any variable on the command line, e.g.:
#   make install CHART_VERSION=26.0.0
# =============================================================================
SHELL          := /usr/bin/env bash
NAMESPACE      ?= dremio
RELEASE        ?= dremio
CHART          ?= oci://quay.io/dremio/dremio-helm
CHART_VERSION  ?= 26.0.0
VALUES         ?= helm/values-openshift-minimal.yaml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Run read-only readiness checks
	./scripts/preflight.sh

.PHONY: prereqs
prereqs: ## Apply namespace, ServiceAccount, SCC and RBAC (SCC needs cluster-admin)
	oc apply -f openshift/01-namespace.yaml
	oc apply -f openshift/02-serviceaccount.yaml
	oc apply -f openshift/03-scc.yaml
	oc apply -f openshift/04-rbac.yaml

.PHONY: values-ref
values-ref: ## Generate the chart's authoritative default values for diffing
	helm show values $(CHART) --version $(CHART_VERSION) > helm/values-reference.generated.yaml
	@echo "wrote helm/values-reference.generated.yaml"

.PHONY: dry-run
dry-run: ## Render/validate the release without installing
	helm upgrade --install $(RELEASE) $(CHART) --version $(CHART_VERSION) \
		--namespace $(NAMESPACE) --values $(VALUES) --dry-run

.PHONY: install
install: ## Full guided install (prereqs + helm + UI route)
	DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) DREMIO_CHART=$(CHART) \
	DREMIO_CHART_VERSION=$(CHART_VERSION) DREMIO_VALUES=$(VALUES) ./scripts/install.sh

.PHONY: helm-only
helm-only: ## Run only the helm upgrade --install step
	helm upgrade --install $(RELEASE) $(CHART) --version $(CHART_VERSION) \
		--namespace $(NAMESPACE) --values $(VALUES) --wait --timeout 15m

.PHONY: route
route: ## Apply the Web UI Route
	oc apply -f openshift/05-route-ui.yaml
	@oc get route dremio-ui -n $(NAMESPACE) -o jsonpath='UI: https://{.spec.host}{"\n"}' || true

.PHONY: status
status: ## Show all Dremio resources
	oc get statefulset,pods,pvc,svc,route -n $(NAMESPACE)
	-helm status $(RELEASE) -n $(NAMESPACE)

.PHONY: logs
logs: ## Tail the master/coordinator log
	oc logs -f dremio-master-0 -n $(NAMESPACE)

.PHONY: uninstall
uninstall: ## Uninstall but KEEP data (PVCs + namespace)
	./scripts/uninstall.sh

.PHONY: purge
purge: ## Uninstall and DELETE everything (DATA LOSS)
	PURGE=1 ./scripts/uninstall.sh
