# =============================================================================
# Dremio 26 (v3 chart) on OpenShift — convenience targets
# =============================================================================
# Pick an environment with ENV=dev|qa|prod (default dev). Examples:
#   make install ENV=dev
#   make dry-run ENV=prod CHART_VERSION=3.2.3
#   make status  ENV=qa
#
# NOTE: CHART_VERSION is the Helm CHART semver (e.g. 3.2.3), NOT the Dremio
# app/image version (26.x). Leave unset for the latest chart.
# =============================================================================
SHELL          := /usr/bin/env bash
ENV            ?= dev
RELEASE        ?= dremio
CHART          ?= oci://quay.io/dremio/dremio-helm
CHART_VERSION  ?=
NAMESPACE      ?= dremio-$(ENV)

VER_ARG := $(if $(CHART_VERSION),--version $(CHART_VERSION),)
VALUES  := -f helm/values-openshift-overrides.yaml \
           -f helm/values-common.yaml \
           -f helm/values-$(ENV).yaml

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo "ENV=$(ENV)  NAMESPACE=$(NAMESPACE)  CHART_VERSION=$(CHART_VERSION)"
	@echo "VALUES: openshift-overrides + common + $(ENV)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Run read-only readiness checks
	DREMIO_NAMESPACE=$(NAMESPACE) ./scripts/preflight.sh

.PHONY: node-tuning
node-tuning: ## Apply the OpenSearch vm.max_map_count Tuned CR (cluster-admin)
	oc apply -f openshift/02-node-tuning-opensearch.yaml

.PHONY: values-ref
values-ref: ## Generate the chart's authoritative default values for diffing
	helm show values $(CHART) $(VER_ARG) > helm/values-reference.generated.yaml
	@echo "wrote helm/values-reference.generated.yaml"

.PHONY: dry-run
dry-run: ## Render/validate the release without installing
	helm upgrade --install $(RELEASE) $(CHART) $(VER_ARG) \
		--namespace $(NAMESPACE) $(VALUES) --dry-run

.PHONY: template
template: ## Render manifests to stdout (inspect what will be applied)
	helm template $(RELEASE) $(CHART) $(VER_ARG) --namespace $(NAMESPACE) $(VALUES)

.PHONY: install
install: ## Full guided install (namespace + node-tuning + helm + UI route)
	ENV=$(ENV) DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) \
	DREMIO_CHART=$(CHART) CHART_VERSION=$(CHART_VERSION) ./scripts/install.sh

.PHONY: helm-only
helm-only: ## Run only the helm upgrade --install step
	helm upgrade --install $(RELEASE) $(CHART) $(VER_ARG) \
		--namespace $(NAMESPACE) $(VALUES) --wait --timeout 30m

.PHONY: route
route: ## Apply the Web UI Route
	sed 's|namespace: dremio$$|namespace: $(NAMESPACE)|g' openshift/03-route-ui.yaml | oc apply -f -
	@oc get route dremio-ui -n $(NAMESPACE) -o jsonpath='UI: https://{.spec.host}{"\n"}' || true

.PHONY: status
status: ## Show all Dremio resources in the ENV namespace
	oc get statefulset,deploy,pods,pvc,svc,route -n $(NAMESPACE)
	-helm status $(RELEASE) -n $(NAMESPACE)

.PHONY: crds
crds: ## List Dremio/operator CRDs installed on the cluster
	oc get crd | grep -iE 'dremio|opensearch|psmdb|percona' || echo "no matching CRDs found"

.PHONY: logs
logs: ## Tail the coordinator (master) log
	oc logs -f dremio-master-0 -n $(NAMESPACE)

.PHONY: uninstall
uninstall: ## Uninstall but KEEP data (PVCs + namespace)
	ENV=$(ENV) DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) ./scripts/uninstall.sh

.PHONY: purge
purge: ## Uninstall and DELETE everything (DATA LOSS)
	PURGE=1 ENV=$(ENV) DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) ./scripts/uninstall.sh
