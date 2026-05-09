STACK           ?= appstack
CLUSTER         ?= k3d-lab-$(shell hostname)
CLUSTER_DOMAIN  ?= $(CLUSTER).local
TARGET_REVISION ?= main

.PHONY: bootstrap
bootstrap:
	./scripts/bootstrap.sh \
		--name $(STACK) \
		--cluster $(CLUSTER) \
		--domain $(CLUSTER_DOMAIN) \
		--version $(TARGET_REVISION) \
		--auto-sync

.PHONY: template
template:
	helm template $(STACK)-apps ./charts/appstack-apps \
		--set stack.name=$(STACK) \
		--set cluster.domain=$(CLUSTER_DOMAIN) \
		--set source.repoURL=https://github.com/your-org/your-repo.git
