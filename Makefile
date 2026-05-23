STACK           ?= appstack
CLUSTER         ?= k3d-lab-$(shell hostname)
CLUSTER_DOMAIN  ?= $(CLUSTER).local
TARGET_REVISION ?= main
CHART_REPO      ?= oci://ghcr.io/your-org/helm
CHART_VERSION   ?=

.PHONY: bootstrap
bootstrap:
	./scripts/bootstrap.sh \
		--name $(STACK) \
		--cluster $(CLUSTER) \
		--domain $(CLUSTER_DOMAIN) \
		--version $(TARGET_REVISION) \
		--chart-repo $(CHART_REPO) \
		--chart-version $(CHART_VERSION) \
		--auto-sync
