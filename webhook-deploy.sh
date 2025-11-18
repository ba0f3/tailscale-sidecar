#!/bin/bash
set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Deploying Tailscale Webhook${NC}"

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo -e "${RED}Error: kubectl is not installed${NC}"
    exit 1
fi

# Check if openssl is available
if ! command -v openssl &> /dev/null; then
    echo -e "${RED}Error: openssl is not installed${NC}"
    exit 1
fi

# Create namespace
echo -e "${YELLOW}Creating namespace...${NC}"
kubectl create namespace tailscale --dry-run=client -o yaml | kubectl apply -f -

# Generate certificates
echo -e "${YELLOW}Generating certificates...${NC}"
./webhook-certs.sh

# Get CA bundle from the generated certificates (handle both Linux and macOS)
if [[ "$OSTYPE" == "darwin"* ]]; then
    CA_BUNDLE=$(cat ./webhook-certs/ca-cert.pem | base64)
else
    CA_BUNDLE=$(cat ./webhook-certs/ca-cert.pem | base64 -w 0)
fi

# Update mutating-webhook.yaml with CA bundle
echo -e "${YELLOW}Updating MutatingWebhookConfiguration with CA bundle...${NC}"
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    sed -i '' "s/CA_BUNDLE_PLACEHOLDER/${CA_BUNDLE}/g" mutating-webhook.yaml
else
    # Linux
    sed -i "s/CA_BUNDLE_PLACEHOLDER/${CA_BUNDLE}/g" mutating-webhook.yaml
fi

# Apply RBAC
echo -e "${YELLOW}Applying RBAC resources...${NC}"
kubectl apply -f webhook-rbac.yaml

# Apply ConfigMap
echo -e "${YELLOW}Applying ConfigMap...${NC}"
kubectl apply -f webhook-configmap.yaml

# Build and push webhook image (optional - user needs to build and push)
echo -e "${YELLOW}Note: You need to build and push the webhook image:${NC}"
echo "  cd webhook-server"
echo "  docker build -t ghcr.io/ba0f3/tailscale-webhook:latest ."
echo "  # Tag and push to your registry if needed"
echo ""

# Apply Deployment and Service
echo -e "${YELLOW}Applying Deployment and Service...${NC}"
kubectl apply -f webhook-deployment.yaml

# Wait for deployment to be ready
echo -e "${YELLOW}Waiting for webhook deployment to be ready...${NC}"
kubectl wait --for=condition=available --timeout=300s deployment/tailscale-webhook -n tailscale

# Apply MutatingWebhookConfiguration
echo -e "${YELLOW}Applying MutatingWebhookConfiguration...${NC}"
kubectl apply -f mutating-webhook.yaml

# Verify deployment
echo -e "${YELLOW}Verifying deployment...${NC}"
kubectl get deployment tailscale-webhook -n tailscale
kubectl get service tailscale-webhook -n tailscale
kubectl get mutatingwebhookconfiguration tailscale-webhook

echo -e "${GREEN}Deployment complete!${NC}"
echo ""
echo -e "${GREEN}To test the webhook, create a pod with the label tailscale.com/inject=true${NC}"
echo "Example:"
echo "  kubectl run test-pod --image=nginx --labels=tailscale.com/inject=true --dry-run=client -o yaml | kubectl apply -f -"

