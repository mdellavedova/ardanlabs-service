

# Check to see if we can use ash, in Alpine images, or default to BASH.
SHELL_PATH = /bin/ash
SHELL = $(if $(wildcard $(SHELL_PATH)),/bin/ash,/bin/bash)

run:
	go run api/services/sales/main.go | go run api/tooling/logfmt/main.go

# ==============================================================================
# Define dependencies

GOLANG          := golang:1.27
ALPINE          := alpine:3.24
KIND            := kindest/node:v1.36.1
POSTGRES        := postgres:18.6
GRAFANA         := grafana/grafana:13.1.3
PROMETHEUS      := prom/prometheus:v3.13.2
TEMPO           := grafana/tempo:3.0.3
LOKI            := grafana/loki:3.7.6
PROMTAIL        := grafana/promtail:3.6.11

KIND_CLUSTER    := ardan-starter-cluster
NAMESPACE       := sales-system
SALES_APP       := sales
AUTH_APP        := auth
BASE_IMAGE_NAME := localhost/ardanlabs
VERSION         := 0.0.1
SALES_IMAGE     := $(BASE_IMAGE_NAME)/$(SALES_APP):$(VERSION)
METRICS_IMAGE   := $(BASE_IMAGE_NAME)/metrics:$(VERSION)
AUTH_IMAGE      := $(BASE_IMAGE_NAME)/$(AUTH_APP):$(VERSION)

# VERSION       := "0.0.1-$(shell git rev-parse --short HEAD)"

# ==============================================================================
# Building containers

build: sales

sales:
	docker build \
		-f zarf/docker/dockerfile.sales \
		-t $(SALES_IMAGE) \
		--build-arg BUILD_TAG=$(VERSION) \
		--build-arg BUILD_DATE=$(date -u +"%Y-%m-%dT%H:%M:%SZ") \
		.

# ==============================================================================
# Running from within k8s/kind
# Docker Desktop 28.3.2 changed how it stores image layers, causing KIND's kind
# load docker-image command to fail with "content digest not found" errors. The
# workaround uses docker save | docker exec to bypass this incompatibility for
# the critical images allowing this to work without a network.

dev-up:
	kind create cluster \
		--image $(KIND) \
		--name $(KIND_CLUSTER) \
		--config zarf/k8s/dev/kind-config.yaml

	kubectl wait --timeout=120s --namespace=local-path-storage --for=condition=Available deployment/local-path-provisioner

	docker save $(POSTGRES) | docker exec -i $(KIND_CLUSTER)-control-plane ctr --namespace=k8s.io images import - & \
	docker save $(GRAFANA) | docker exec -i $(KIND_CLUSTER)-control-plane ctr --namespace=k8s.io images import - & \
	docker save $(PROMETHEUS) | docker exec -i $(KIND_CLUSTER)-control-plane ctr --namespace=k8s.io images import - & \
	docker save $(TEMPO) | docker exec -i $(KIND_CLUSTER)-control-plane ctr --namespace=k8s.io images import - & \
	docker save $(LOKI) | docker exec -i $(KIND_CLUSTER)-control-plane ctr --namespace=k8s.io images import - & \
	docker save $(PROMTAIL) | docker exec -i $(KIND_CLUSTER)-control-plane ctr --namespace=k8s.io images import - & \
	wait;

dev-down:
	kind delete cluster --name $(KIND_CLUSTER)

dev-status-all:
	kubectl get nodes -o wide
	kubectl get svc -o wide
	kubectl get pods -o wide --watch --all-namespaces

dev-status:
	watch -n 2 kubectl get pods -o wide --all-namespaces
# ------------------------------------------------------------------------------
dev-load:
	kind load docker-image $(SALES_IMAGE) --name $(KIND_CLUSTER)

dev-apply:
	kustomize build zarf/k8s/dev/sales | kubectl apply -f -
	kubectl wait pods --namespace=$(NAMESPACE) --selector app=$(SALES_APP) --timeout=120s --for=condition=Ready

dev-restart:
	kubectl rollout restart deployment $(SALES_APP) --namespace=$(NAMESPACE)

dev-update: build dev-load dev-restart

dev-update-apply: build dev-load dev-apply

dev-logs:
	kubectl logs --namespace=$(NAMESPACE) -l app=$(SALES_APP) --all-containers=true -f --tail=100 --max-log-requests=6 | go run api/tooling/logfmt/main.go -service=$(SALES_APP)

# ------------------------------------------------------------------------------

dev-describe-deployment:
	kubectl describe deployment --namespace=$(NAMESPACE) $(SALES_APP)

dev-describe-sales:
	kubectl describe pod --namespace=$(NAMESPACE) -l app=$(SALES_APP)
# ==============================================================================
# Modules support

tidy:
	go mod tidy
	go mod vendor
