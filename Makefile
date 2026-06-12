# =============================================================================
# Dremio 26 on OpenShift — convenience targets
# =============================================================================
# Pick an environment with ENV=dev|qa|prod (omit for the single-namespace
# minimal/POC profile). Examples:
#   make install ENV=dev
#   make dry-run ENV=prod CHART_VERSION=26.0.0
#   make status  ENV=qa
# =============================================================================
SHELL          := /usr/bin/env bash
ENV            ?=
RELEASE        ?= dremio
CHART          ?= oci://quay.io/dremio/dremio-helm
CHART_VERSION  ?= 26.0.0

# Resolve namespace + values files from ENV.
ifeq ($(ENV),)
  NAMESPACE    ?= dremio
  VALUES_FILES := helm/values-openshift-minimal.yaml
else
  NAMESPACE    ?= dremio-$(ENV)
  VALUES_FILES := helm/values-common.yaml helm/values-$(ENV).yaml
endif
VALUES_ARGS := $(addprefix --values ,$(VALUES_FILES))

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo "ENV=$(ENV)  NAMESPACE=$(NAMESPACE)  VALUES=$(VALUES_FILES)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

.PHONY: preflight
preflight: ## Run read-only readiness checks
	DREMIO_NAMESPACE=$(NAMESPACE) ./scripts/preflight.sh

.PHONY: values-ref
values-ref: ## Generate the chart's authoritative default values for diffing
	helm show values $(CHART) --version $(CHART_VERSION) > helm/values-reference.generated.yaml
	@echo "wrote helm/values-reference.generated.yaml"

.PHONY: dry-run
dry-run: ## Render/validate the release without installing
	helm upgrade --install $(RELEASE) $(CHART) --version $(CHART_VERSION) \
		--namespace $(NAMESPACE) $(VALUES_ARGS) --dry-run

.PHONY: install
install: ## Full guided install (prereqs + helm + UI route) for ENV
	ENV=$(ENV) DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) \
	DREMIO_CHART=$(CHART) DREMIO_CHART_VERSION=$(CHART_VERSION) ./scripts/install.sh

.PHONY: helm-only
helm-only: ## Run only the helm upgrade --install step for ENV
	helm upgrade --install $(RELEASE) $(CHART) --version $(CHART_VERSION) \
		--namespace $(NAMESPACE) $(VALUES_ARGS) --wait --timeout 20m

.PHONY: status
status: ## Show all Dremio resources in the ENV namespace
	oc get statefulset,pods,pvc,svc,route -n $(NAMESPACE)
	-helm status $(RELEASE) -n $(NAMESPACE)

.PHONY: logs
logs: ## Tail the master/coordinator log
	oc logs -f dremio-master-0 -n $(NAMESPACE)

.PHONY: uninstall
uninstall: ## Uninstall but KEEP data (PVCs + namespace)
	ENV=$(ENV) DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) ./scripts/uninstall.sh

.PHONY: purge
purge: ## Uninstall and DELETE everything (DATA LOSS)
	PURGE=1 ENV=$(ENV) DREMIO_NAMESPACE=$(NAMESPACE) DREMIO_RELEASE=$(RELEASE) ./scripts/uninstall.sh
