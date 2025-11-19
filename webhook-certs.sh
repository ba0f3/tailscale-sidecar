#!/bin/bash
set -e

# Configuration
NAMESPACE="tailscale"
SERVICE_NAME="tailscale-webhook"
SECRET_NAME="tailscale-webhook-certs"
WEBHOOK_NAME="tailscale-webhook"
CERT_DIR="./webhook-certs"

# Create cert directory
mkdir -p "${CERT_DIR}"

# Generate CA private key
openssl genrsa -out "${CERT_DIR}/ca-key.pem" 2048

# Generate CA certificate
openssl req -x509 -new -nodes -key "${CERT_DIR}/ca-key.pem" -subj "/CN=${SERVICE_NAME}.${NAMESPACE}.svc" -days 10000 -out "${CERT_DIR}/ca-cert.pem"

# Generate server private key
openssl genrsa -out "${CERT_DIR}/server-key.pem" 2048

# Generate server certificate signing request
cat > "${CERT_DIR}/server.conf" <<EOF
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name
[req_distinguished_name]
[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${SERVICE_NAME}
DNS.2 = ${SERVICE_NAME}.${NAMESPACE}
DNS.3 = ${SERVICE_NAME}.${NAMESPACE}.svc
DNS.4 = ${SERVICE_NAME}.${NAMESPACE}.svc.cluster.local
EOF

openssl req -new -key "${CERT_DIR}/server-key.pem" -subj "/CN=${SERVICE_NAME}.${NAMESPACE}.svc" -out "${CERT_DIR}/server.csr" -config "${CERT_DIR}/server.conf"

# Generate server certificate
openssl x509 -req -in "${CERT_DIR}/server.csr" -CA "${CERT_DIR}/ca-cert.pem" -CAkey "${CERT_DIR}/ca-key.pem" \
  -CAcreateserial -out "${CERT_DIR}/server-cert.pem" -days 10000 \
  -extensions v3_req -extfile "${CERT_DIR}/server.conf"

# Base64 encode certificates (handle both Linux and macOS)
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    CA_BUNDLE=$(cat "${CERT_DIR}/ca-cert.pem" | base64)
    SERVER_CERT=$(cat "${CERT_DIR}/server-cert.pem" | base64)
    SERVER_KEY=$(cat "${CERT_DIR}/server-key.pem" | base64)
else
    # Linux
    CA_BUNDLE=$(cat "${CERT_DIR}/ca-cert.pem" | base64 -w 0)
    SERVER_CERT=$(cat "${CERT_DIR}/server-cert.pem" | base64 -w 0)
    SERVER_KEY=$(cat "${CERT_DIR}/server-key.pem" | base64 -w 0)
fi

# Create or update Kubernetes secret
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

kubectl create secret generic "${SECRET_NAME}" \
  --namespace="${NAMESPACE}" \
  --from-file=tls.crt="${CERT_DIR}/server-cert.pem" \
  --from-file=tls.key="${CERT_DIR}/server-key.pem" \
  --from-file=ca.crt="${CERT_DIR}/ca-cert.pem" \
  --dry-run=client -o yaml | kubectl apply -f -

# Update mutating-webhook.yaml with CA bundle
if [ -f "mutating-webhook.yaml" ]; then
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "s|caBundle: .*|caBundle: ${CA_BUNDLE}|" mutating-webhook.yaml
    else
        sed -i "s|caBundle: .*|caBundle: ${CA_BUNDLE}|" mutating-webhook.yaml
    fi
    echo "Updated mutating-webhook.yaml with new CA bundle"
else
    echo "Warning: mutating-webhook.yaml not found"
fi

# Update MutatingWebhookConfiguration with CA bundle (live object)
if kubectl get mutatingwebhookconfiguration "${WEBHOOK_NAME}" &>/dev/null; then
  kubectl patch mutatingwebhookconfiguration "${WEBHOOK_NAME}" --type='json' \
    -p="[{\"op\": \"replace\", \"path\": \"/webhooks/0/clientConfig/caBundle\", \"value\": \"${CA_BUNDLE}\"}]"
else
  echo "Warning: MutatingWebhookConfiguration ${WEBHOOK_NAME} not found. Please apply mutating-webhook.yaml after updating CA_BUNDLE_PLACEHOLDER with:"
  echo "${CA_BUNDLE}"
fi

echo ""
echo "Certificates generated successfully!"
echo "CA Bundle (for MutatingWebhookConfiguration):"
echo "${CA_BUNDLE}"
echo ""
echo "Certificates are stored in: ${CERT_DIR}"
echo "Secret ${SECRET_NAME} has been created/updated in namespace ${NAMESPACE}"

