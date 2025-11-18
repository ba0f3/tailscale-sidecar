# Tailscale Sidecar Auto-Injection Webhook

This webhook automatically injects the Tailscale sidecar container into pods labeled with `tailscale.com/inject: "true"`.

## Overview

The MutatingAdmissionWebhook watches for pod creation events and automatically injects the Tailscale sidecar container (in privileged mode) when a pod has the `tailscale.com/inject: "true"` label.

## Architecture

- **Webhook Server**: Go-based HTTP server that handles admission requests
- **MutatingWebhookConfiguration**: Kubernetes resource that registers the webhook
- **Deployment**: Runs the webhook server in the `tailscale` namespace
- **Service**: Exposes the webhook server internally
- **RBAC**: Permissions for the webhook to read pods

## Prerequisites

- Kubernetes cluster (v1.23+)
- `kubectl` configured to access your cluster
- `openssl` for certificate generation
- Docker (for building the webhook image)
- Go 1.21+ (for building the webhook server)

## Quick Start

### Option 1: Using Makefile (Recommended)

```bash
# Show all available targets
make help

# Build the Docker image
make build

# Or build and push to registry
make push IMAGE_REGISTRY=your-registry

# Deploy the webhook (generates certs, updates image, applies manifests)
make deploy

# Create and verify test pod
make test

# Check status
make status

# View logs
make logs
```

### Option 2: Manual Deployment

#### 1. Build the Webhook Image

```bash
cd webhook-server
docker build -t tailscale-webhook:latest .
```

If using a container registry:
```bash
docker tag tailscale-webhook:latest your-registry/tailscale-webhook:latest
docker push your-registry/tailscale-webhook:latest
```

Then update `webhook-deployment.yaml` with your image name, or use:
```bash
make update-image IMAGE_REGISTRY=your-registry
```

#### 2. Deploy the Webhook

```bash
# Make scripts executable
chmod +x webhook-certs.sh webhook-deploy.sh

# Deploy everything
./webhook-deploy.sh
```

Or deploy manually:

```bash
# Create namespace
kubectl create namespace tailscale

# Generate certificates
./webhook-certs.sh

# Get CA bundle
CA_BUNDLE=$(cat ./webhook-certs/ca-cert.pem | base64 -w 0)

# Update mutating-webhook.yaml with CA bundle
sed -i "s/CA_BUNDLE_PLACEHOLDER/${CA_BUNDLE}/g" mutating-webhook.yaml

# Apply resources
kubectl apply -f webhook-rbac.yaml
kubectl apply -f webhook-configmap.yaml
kubectl apply -f webhook-deployment.yaml
kubectl apply -f mutating-webhook.yaml
```

### 3. Verify Deployment

```bash
# Check webhook pod
kubectl get pods -n tailscale -l app=tailscale-webhook

# Check webhook logs
kubectl logs -n tailscale -l app=tailscale-webhook

# Verify MutatingWebhookConfiguration
kubectl get mutatingwebhookconfiguration tailscale-webhook
```

## Usage

### Inject Sidecar into a Pod

Add the label `tailscale.com/inject: "true"` to your pod:

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: my-app
  labels:
    tailscale.com/inject: "true"
spec:
  containers:
  - name: app
    image: nginx
```

Or using kubectl:

```bash
kubectl run my-app --image=nginx --labels=tailscale.com/inject=true
```

### Verify Sidecar Injection

```bash
# Check pod containers
kubectl get pod my-app -o jsonpath='{.spec.containers[*].name}'
# Should show: app ts-sidecar-<namespace>-<pod-name>

# Describe pod to see sidecar details
kubectl describe pod my-app

# Check sidecar hostname
kubectl get pod my-app -o jsonpath='{.spec.containers[?(@.name=="ts-sidecar-*")].env[?(@.name=="TS_HOSTNAME")].value}'
# Should show: <pod-name>-<namespace>
```

### Disable Injection for a Namespace

Add label to namespace:

```bash
kubectl label namespace my-namespace tailscale.com/inject=disabled
```

## Makefile Usage

The Makefile provides convenient targets for building, deploying, and managing the webhook:

### Common Commands

```bash
# Show all available targets
make help

# Build Docker image
make build

# Build and push to registry
make push IMAGE_REGISTRY=your-registry

# Deploy webhook (generates certs, updates image, applies manifests)
make deploy

# Quick deploy (skip certificate regeneration)
make deploy-quick

# Create test pod and verify injection
make test

# Check webhook status
make status

# View webhook logs
make logs

# Restart webhook
make restart

# Update login server configuration
make config-update LOGIN_SERVER=https://your-headscale-server.com

# Clean up (remove test pod and certificates)
make clean

# Remove everything including webhook deployment
make clean-all
```

### Customizing Image Registry

You can customize the image registry and tag:

```bash
# Build with custom registry
make build IMAGE_REGISTRY=ghcr.io/your-org

# Push with custom registry and tag
make push IMAGE_REGISTRY=ghcr.io/your-org IMAGE_TAG=v1.0.0

# Deploy with custom image
make deploy IMAGE_REGISTRY=ghcr.io/your-org IMAGE_TAG=v1.0.0
```

## Configuration

### Environment Variables

The webhook server supports these environment variables (set in `webhook-deployment.yaml`):

- `PORT`: Webhook server port (default: 8443)
- `TLS_CERT`: Path to TLS certificate (default: /etc/webhook/certs/tls.crt)
- `TLS_KEY`: Path to TLS private key (default: /etc/webhook/certs/tls.key)
- `TS_EXTRA_ARGS`: Tailscale extra arguments (configurable via ConfigMap `tailscale-webhook-config.ts-extra-args`, default: empty)
- `TS_KUBE_SECRET`: Pattern for Kubernetes secret name (optional)

### ConfigMap Configuration

The webhook reads configuration from the `tailscale-webhook-config` ConfigMap:

- `ts-extra-args`: Tailscale extra arguments (e.g., `--login-server=https://your-headscale-server.com`). This allows you to change the Headscale login server without rebuilding the webhook image.
- `ts-kube-secret-pattern`: Pattern for Kubernetes secret names. Supports template variables:
  - `{{NAMESPACE}}` - Replaced with pod namespace
  - `{{POD_NAME}}` - Replaced with pod name
  - `{{POD_UID}}` - Replaced with pod UID
  - Example: `tailscale-{{NAMESPACE}}-{{POD_NAME}}` becomes `tailscale-default-my-pod`
  - The pattern is automatically sanitized to comply with Kubernetes DNS-1123 subdomain requirements

To update the login server:
```bash
kubectl patch configmap tailscale-webhook-config -n tailscale --type merge -p '{"data":{"ts-extra-args":"--login-server=https://your-headscale-server.com"}}'
kubectl rollout restart deployment/tailscale-webhook -n tailscale
```

### Sidecar Configuration

The injected sidecar matches the configuration from `sidecar.yaml`:

- **Image**: `ghcr.io/tailscale/tailscale:latest`
- **Mode**: Privileged (requires privileged security context)
- **Container Name**: `ts-sidecar-<namespace>-<pod-name>` (unique per pod to avoid name collisions)
- **Environment Variables**:
  - `TS_EXTRA_ARGS`: Login server URL (configurable via ConfigMap)
  - `TS_HOSTNAME`: Unique hostname format `<pod-name>-<namespace>` to avoid Headscale name collisions
  - `TS_KUBE_SECRET`: Kubernetes secret name for state storage (generated from pattern in ConfigMap, e.g., `tailscale-<namespace>-<pod-name>`)
  - `TS_USERSPACE`: false (privileged mode)
  - `TS_DEBUG_FIREWALL_MODE`: auto
  - `TS_AUTHKEY`: From `tailscale-auth` secret
  - `POD_NAME` and `POD_UID`: From pod metadata

**Note**: Each sidecar gets a unique container name and hostname to prevent collisions in Headscale when multiple pods with the same name exist in different namespaces or when pods are recreated.

### Service Account

The webhook uses the pod's existing service account. If the pod doesn't have one, it will use the `default` service account. Ensure the service account has the necessary permissions (see `role.yaml` and `rolebinding.yaml` for reference).

## Troubleshooting

### Webhook Not Injecting Sidecar

1. **Check webhook pod is running**:
   ```bash
   kubectl get pods -n tailscale -l app=tailscale-webhook
   ```

2. **Check webhook logs**:
   ```bash
   kubectl logs -n tailscale -l app=tailscale-webhook
   ```

3. **Verify pod has correct label**:
   ```bash
   kubectl get pod <pod-name> -o jsonpath='{.metadata.labels.tailscale\.com/inject}'
   ```

4. **Check MutatingWebhookConfiguration**:
   ```bash
   kubectl get mutatingwebhookconfiguration tailscale-webhook -o yaml
   ```

5. **Check webhook admission**:
   ```bash
   kubectl get events --field-selector involvedObject.name=<pod-name> --sort-by='.lastTimestamp'
   ```

### Certificate Issues

If certificates expire or need regeneration:

```bash
# Regenerate certificates
./webhook-certs.sh

# Restart webhook pod
kubectl rollout restart deployment/tailscale-webhook -n tailscale
```

### Sidecar Already Exists

The webhook checks if `ts-sidecar` container already exists and skips injection if found. This prevents duplicate sidecars.

## Files

- `webhook-server/`: Go webhook server implementation
  - `main.go`: Webhook server code
  - `Dockerfile`: Container image definition
  - `go.mod`: Go dependencies
- `webhook-deployment.yaml`: Deployment and Service manifests
- `webhook-rbac.yaml`: RBAC resources
- `webhook-configmap.yaml`: Configuration ConfigMap
- `mutating-webhook.yaml`: MutatingWebhookConfiguration
- `webhook-certs.sh`: Certificate generation script
- `webhook-deploy.sh`: Deployment automation script

## Security Considerations

1. **TLS**: The webhook uses TLS for secure communication. Certificates are self-signed for development. For production, consider using cert-manager or a proper CA.

2. **RBAC**: The webhook only has read permissions on pods. It cannot modify other resources.

3. **Privileged Mode**: The injected sidecar runs in privileged mode, which grants elevated permissions. Ensure your cluster security policies allow this.

4. **Namespace Isolation**: The webhook can be disabled per namespace using the `tailscale.com/inject=disabled` label.

## Uninstallation

```bash
# Delete MutatingWebhookConfiguration
kubectl delete mutatingwebhookconfiguration tailscale-webhook

# Delete Deployment and Service
kubectl delete -f webhook-deployment.yaml

# Delete RBAC
kubectl delete -f webhook-rbac.yaml

# Delete ConfigMap
kubectl delete -f webhook-configmap.yaml

# Delete certificates (optional)
rm -rf webhook-certs/
```

## References

- [Kubernetes Admission Controllers](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [MutatingAdmissionWebhook](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/#mutatingadmissionwebhook)
- [Tailscale Kubernetes Operator](https://tailscale.com/kb/1236/kubernetes-operator)

