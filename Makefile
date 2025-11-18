# Makefile for Tailscale Webhook

# Variables
IMAGE_NAME ?= tailscale-webhook
IMAGE_TAG ?= latest
IMAGE_REGISTRY ?= ghcr.io/ba0f3
FULL_IMAGE_NAME = $(IMAGE_REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

NAMESPACE = tailscale
WEBHOOK_NAME = tailscale-webhook
CERT_DIR = ./webhook-certs

# Colors for output
COLOR_RESET = \033[0m
COLOR_INFO = \033[1;34m
COLOR_SUCCESS = \033[1;32m
COLOR_WARNING = \033[1;33m
COLOR_ERROR = \033[1;31m

.PHONY: help build build-local push deploy deploy-quick undeploy test-pod-create test-pod-delete test-pod-verify test clean clean-all certs logs status restart update-image config-update

help: ## Show this help message
	@echo "$(COLOR_INFO)Available targets:$(COLOR_RESET)"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  $(COLOR_SUCCESS)%-20s$(COLOR_RESET) %s\n", $$1, $$2}'

build: ## Build the Docker image
	@echo "$(COLOR_INFO)Building Docker image: $(FULL_IMAGE_NAME)$(COLOR_RESET)"
	cd webhook-server && docker build -t $(FULL_IMAGE_NAME) .
	@echo "$(COLOR_SUCCESS)Build complete!$(COLOR_RESET)"

build-local: ## Build the Docker image with local tag
	@echo "$(COLOR_INFO)Building Docker image: $(IMAGE_NAME):$(IMAGE_TAG)$(COLOR_RESET)"
	cd webhook-server && docker build -t $(IMAGE_NAME):$(IMAGE_TAG) .
	@echo "$(COLOR_SUCCESS)Build complete!$(COLOR_RESET)"

push: build ## Build and push the Docker image to registry
	@echo "$(COLOR_INFO)Pushing Docker image: $(FULL_IMAGE_NAME)$(COLOR_RESET)"
	docker push $(FULL_IMAGE_NAME)
	@echo "$(COLOR_SUCCESS)Push complete!$(COLOR_RESET)"

certs: ## Generate TLS certificates for the webhook
	@echo "$(COLOR_INFO)Generating TLS certificates...$(COLOR_RESET)"
	@if [ ! -f webhook-certs.sh ]; then \
		echo "$(COLOR_ERROR)Error: webhook-certs.sh not found$(COLOR_RESET)"; \
		exit 1; \
	fi
	chmod +x webhook-certs.sh
	./webhook-certs.sh
	@echo "$(COLOR_SUCCESS)Certificates generated!$(COLOR_RESET)"

update-image: ## Update the image in deployment.yaml
	@echo "$(COLOR_INFO)Updating image in webhook-deployment.yaml to $(FULL_IMAGE_NAME)$(COLOR_RESET)"
	@if command -v sed >/dev/null 2>&1; then \
		if [[ "$$OSTYPE" == "darwin"* ]]; then \
			sed -i '' 's|image:.*tailscale-webhook.*|image: $(FULL_IMAGE_NAME)|' webhook-deployment.yaml; \
		else \
			sed -i 's|image:.*tailscale-webhook.*|image: $(FULL_IMAGE_NAME)|' webhook-deployment.yaml; \
		fi; \
		echo "$(COLOR_SUCCESS)Image updated!$(COLOR_RESET)"; \
	else \
		echo "$(COLOR_WARNING)sed not found, please manually update webhook-deployment.yaml$(COLOR_RESET)"; \
	fi

deploy: certs update-image ## Deploy the webhook (generates certs, updates image, applies manifests)
	@echo "$(COLOR_INFO)Deploying Tailscale Webhook...$(COLOR_RESET)"
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f webhook-rbac.yaml
	@kubectl apply -f webhook-configmap.yaml
	@kubectl apply -f webhook-deployment.yaml
	@echo "$(COLOR_INFO)Waiting for deployment to be ready...$(COLOR_RESET)"
	@kubectl wait --for=condition=available --timeout=300s deployment/$(WEBHOOK_NAME) -n $(NAMESPACE) || true
	@kubectl apply -f mutating-webhook.yaml
	@echo "$(COLOR_SUCCESS)Deployment complete!$(COLOR_RESET)"

deploy-quick: ## Deploy without regenerating certificates (faster)
	@echo "$(COLOR_INFO)Quick deploy (skipping certificate generation)...$(COLOR_RESET)"
	@kubectl create namespace $(NAMESPACE) --dry-run=client -o yaml | kubectl apply -f -
	@kubectl apply -f webhook-rbac.yaml
	@kubectl apply -f webhook-configmap.yaml
	@kubectl apply -f webhook-deployment.yaml
	@kubectl apply -f mutating-webhook.yaml
	@echo "$(COLOR_SUCCESS)Quick deploy complete!$(COLOR_RESET)"

undeploy: ## Remove the webhook from the cluster
	@echo "$(COLOR_WARNING)Removing Tailscale Webhook...$(COLOR_RESET)"
	@kubectl delete mutatingwebhookconfiguration $(WEBHOOK_NAME) --ignore-not-found=true
	@kubectl delete -f webhook-deployment.yaml --ignore-not-found=true
	@kubectl delete -f webhook-rbac.yaml --ignore-not-found=true
	@kubectl delete -f webhook-configmap.yaml --ignore-not-found=true
	@echo "$(COLOR_SUCCESS)Undeploy complete!$(COLOR_RESET)"

test-pod-create: ## Create test pod to verify webhook injection
	@echo "$(COLOR_INFO)Creating test pod...$(COLOR_RESET)"
	@kubectl delete pod test-tailscale-injection --ignore-not-found=true
	@sleep 2
	@kubectl apply -f webhook-test-pod.yaml
	@echo "$(COLOR_SUCCESS)Test pod created!$(COLOR_RESET)"
	@echo "$(COLOR_INFO)Waiting for pod to be ready...$(COLOR_RESET)"
	@kubectl wait --for=condition=ready pod/test-tailscale-injection --timeout=60s || true

test-pod-delete: ## Delete the test pod
	@echo "$(COLOR_INFO)Deleting test pod...$(COLOR_RESET)"
	@kubectl delete pod test-tailscale-injection --ignore-not-found=true
	@echo "$(COLOR_SUCCESS)Test pod deleted!$(COLOR_RESET)"

test-pod-verify: ## Verify that sidecar was injected into test pod
	@echo "$(COLOR_INFO)Verifying sidecar injection...$(COLOR_RESET)"
	@echo "$(COLOR_INFO)Containers in pod:$(COLOR_RESET)"
	@kubectl get pod test-tailscale-injection -o jsonpath='{.spec.containers[*].name}' 2>/dev/null | tr ' ' '\n' | sed 's/^/  - /' || echo "$(COLOR_ERROR)Pod not found$(COLOR_RESET)"
	@echo ""
	@echo "$(COLOR_INFO)Sidecar container details:$(COLOR_RESET)"
	@kubectl get pod test-tailscale-injection -o jsonpath='{.spec.containers[?(@.name=~"ts-sidecar.*")].name}' 2>/dev/null && \
		echo "$(COLOR_SUCCESS)✓ Sidecar found!$(COLOR_RESET)" || \
		echo "$(COLOR_ERROR)✗ Sidecar not found$(COLOR_RESET)"
	@echo ""
	@echo "$(COLOR_INFO)TS_HOSTNAME value:$(COLOR_RESET)"
	@kubectl get pod test-tailscale-injection -o jsonpath='{.spec.containers[?(@.name=~"ts-sidecar.*")].env[?(@.name=="TS_HOSTNAME")].value}' 2>/dev/null || echo "Not found"
	@echo ""

test: test-pod-create test-pod-verify ## Create test pod and verify injection

logs: ## Show webhook server logs
	@echo "$(COLOR_INFO)Webhook server logs:$(COLOR_RESET)"
	@kubectl logs -n $(NAMESPACE) -l app=$(WEBHOOK_NAME) --tail=50 -f

status: ## Show webhook deployment status
	@echo "$(COLOR_INFO)Webhook Deployment Status:$(COLOR_RESET)"
	@echo ""
	@kubectl get deployment $(WEBHOOK_NAME) -n $(NAMESPACE) 2>/dev/null || echo "$(COLOR_ERROR)Deployment not found$(COLOR_RESET)"
	@echo ""
	@echo "$(COLOR_INFO)Webhook Pods:$(COLOR_RESET)"
	@kubectl get pods -n $(NAMESPACE) -l app=$(WEBHOOK_NAME) 2>/dev/null || echo "$(COLOR_ERROR)No pods found$(COLOR_RESET)"
	@echo ""
	@echo "$(COLOR_INFO)MutatingWebhookConfiguration:$(COLOR_RESET)"
	@kubectl get mutatingwebhookconfiguration $(WEBHOOK_NAME) 2>/dev/null || echo "$(COLOR_ERROR)MutatingWebhookConfiguration not found$(COLOR_RESET)"

restart: ## Restart the webhook deployment
	@echo "$(COLOR_INFO)Restarting webhook deployment...$(COLOR_RESET)"
	@kubectl rollout restart deployment/$(WEBHOOK_NAME) -n $(NAMESPACE)
	@kubectl rollout status deployment/$(WEBHOOK_NAME) -n $(NAMESPACE) --timeout=120s
	@echo "$(COLOR_SUCCESS)Restart complete!$(COLOR_RESET)"

clean: ## Clean up generated certificates and test pod
	@echo "$(COLOR_INFO)Cleaning up...$(COLOR_RESET)"
	@kubectl delete pod test-tailscale-injection --ignore-not-found=true
	@if [ -d $(CERT_DIR) ]; then \
		echo "$(COLOR_WARNING)Removing certificate directory: $(CERT_DIR)$(COLOR_RESET)"; \
		rm -rf $(CERT_DIR); \
	fi
	@echo "$(COLOR_SUCCESS)Cleanup complete!$(COLOR_RESET)"

clean-all: clean undeploy ## Clean everything including webhook deployment

config-update: ## Update ConfigMap with new login server (usage: make config-update LOGIN_SERVER=https://your-server.com)
	@if [ -z "$(LOGIN_SERVER)" ]; then \
		echo "$(COLOR_ERROR)Error: LOGIN_SERVER not set. Usage: make config-update LOGIN_SERVER=https://your-server.com$(COLOR_RESET)"; \
		exit 1; \
	fi
	@echo "$(COLOR_INFO)Updating ConfigMap with login server: $(LOGIN_SERVER)$(COLOR_RESET)"
	@kubectl patch configmap tailscale-webhook-config -n $(NAMESPACE) --type merge \
		-p "{\"data\":{\"ts-extra-args\":\"--login-server=$(LOGIN_SERVER)\"}}"
	@echo "$(COLOR_SUCCESS)ConfigMap updated!$(COLOR_RESET)"
	@echo "$(COLOR_INFO)Restarting webhook to apply changes...$(COLOR_RESET)"
	@$(MAKE) restart

.DEFAULT_GOAL := help

