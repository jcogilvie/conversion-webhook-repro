#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "🚀 Setting up Kubernetes CRD Conversion Webhook Failure Reproduction"
echo "=================================================================="

# Step 1: Create two Kind clusters
echo "📦 Creating Kind clusters..."
kind create cluster --name argocd-cluster
kind create cluster --name target-cluster

# Step 2: Build and load webhook server
echo "🔨 Building webhook server..."
docker build -t webhook-conversion:latest .
kind load docker-image webhook-conversion:latest --name target-cluster

# Step 3: Setup target cluster with CRD and webhook
echo "🎯 Setting up target cluster..."
kubectl config use-context kind-target-cluster
kubectl create namespace webhook-system

# Install the ProviderRevision CRD (simulating Crossplane installation)
echo "📦 Installing ProviderRevision CRD (simulating Crossplane)..."
kubectl apply -f manifests/provider-revision-crd.yaml

# Create a fake ProviderRevision to own our CRD (simulating Crossplane)
echo "📦 Creating fake ProviderRevision..."
kubectl apply -f manifests/fake-provider-revision.yaml

# Get the UID of the ProviderRevision to use in owner references
PROVIDER_REVISION_UID=$(kubectl get providerrevision example-provider-revision-12345 -n webhook-system -o jsonpath='{.metadata.uid}')
echo "🔍 ProviderRevision UID: $PROVIDER_REVISION_UID"

# Create CRD with owner reference to the ProviderRevision
echo "📋 Creating CRD with owner references..."
sed "s/PLACEHOLDER_UID/$PROVIDER_REVISION_UID/g" manifests/crd-with-owner-refs.yaml | kubectl apply -f -

# Step 4: Generate TLS certificates
echo "🔐 Generating TLS certificates..."
mkdir -p /tmp/webhook-certs
cd /tmp/webhook-certs

openssl genrsa -out ca.key 2048
openssl req -new -x509 -days 365 -key ca.key -out ca.crt -subj "/C=CA/ST=Province/O=Example"
openssl genrsa -out tls.key 2048
openssl req -new -key tls.key -out server.csr -subj "/C=CA/ST=Province/O=Example" -addext "subjectAltName=DNS:conversion-webhook-service.webhook-system.svc,DNS:conversion-webhook-service.webhook-system.svc.cluster.local"
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -days 365 -extensions v3_req -extfile <(echo -e "[ v3_req ]\nsubjectAltName=DNS:conversion-webhook-service.webhook-system.svc,DNS:conversion-webhook-service.webhook-system.svc.cluster.local")

kubectl create secret tls webhook-certs \
  --cert=tls.crt \
  --key=tls.key \
  -n webhook-system

CA_BUNDLE=$(cat ca.crt | base64 | tr -d '\n')
kubectl patch crd examples.conversion.example.com --type='merge' -p='{"spec":{"conversion":{"webhook":{"clientConfig":{"caBundle":"'$CA_BUNDLE'"}}}}}'

# Return to project root
cd -

# Step 5: Deploy webhook service
echo "🌐 Deploying webhook service..."
# Ensure we're still in target cluster context
kubectl config use-context kind-target-cluster
kubectl apply -f manifests/webhook-deployment.yaml

# Step 6: Verify target cluster setup
echo "✅ Verifying target cluster setup..."
echo "🔍 Current context: $(kubectl config current-context)"

echo "🔍 Checking webhook deployment status..."
kubectl get deployments -n webhook-system || echo "No deployments found"

echo "🔍 Checking for webhook pods..."
kubectl get pods -n webhook-system -l app=conversion-webhook || echo "No webhook pods found yet"

# Check if deployment exists and is progressing
if kubectl get deployment conversion-webhook -n webhook-system >/dev/null 2>&1; then
    echo "⏳ Waiting for webhook deployment to create pods..."
    kubectl rollout status deployment/conversion-webhook -n webhook-system --timeout=120s

    echo "⏳ Waiting for webhook pod to be ready..."
    kubectl wait --for=condition=ready pod -l app=conversion-webhook -n webhook-system --timeout=60s
else
    echo "❌ Webhook deployment not found! Check the manifest."
    exit 1
fi

echo "✅ Webhook pod is ready. Checking CRD..."
kubectl get crd examples.conversion.example.com

echo "📋 Applying test resources..."
kubectl apply -f manifests/test-resources.yaml

echo "🔍 Checking created examples..."
kubectl get examples

# Step 7: Install Argo CD in management cluster
echo "🎛️  Installing Argo CD..."
kubectl config use-context kind-argocd-cluster
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server.insecure"=true \
  --version 7.6.10

kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Allow argo to manage itself (for visibility)
echo "🎛️  Applying Argo CD self Application manifest..."
kubectl apply -f manifests/argocd.yaml

# Step 8: Get Argo CD password and save it
echo "🔑 Getting Argo CD credentials..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

# Step 9: Add target cluster to Argo CD
echo "🔗 Registering target cluster with Argo CD..."

# Get the target cluster server URL - need to use Docker network IP, not localhost
echo "🔍 Getting target cluster connection details..."
TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
echo "🔍 Raw target server URL: $TARGET_SERVER_RAW"

# Extract port from the localhost URL
TARGET_PORT=$(echo $TARGET_SERVER_RAW | sed 's/.*://')
echo "🔍 Target cluster port: $TARGET_PORT"

# Get the Docker container IP for the target cluster
TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "🔍 Target cluster Docker IP: $TARGET_CONTAINER_IP"

# Construct the target server URL using Docker network IP
TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"
echo "🔍 Target server URL for Argo CD: $TARGET_SERVER"

kubectl config use-context kind-target-cluster
kubectl create serviceaccount argocd-manager -n kube-system
kubectl create clusterrolebinding argocd-manager-binding --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager
kubectl apply -f manifests/argocd-manager-token.yaml

TOKEN=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
CA_CERT=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.ca\.crt}')

kubectl config use-context kind-argocd-cluster
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g; s|TOKEN_PLACEHOLDER|$TOKEN|g; s|CA_CERT_PLACEHOLDER|$CA_CERT|g" manifests/target-cluster-secret.yaml | kubectl apply -f -

# Step 10-11: Create and verify cross-cluster applications
echo "📱 Creating cross-cluster applications..."
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g" manifests/external-cluster-applications.yaml | kubectl apply -f -

echo "⏳ Waiting for applications to sync..."
echo "🔍 If this hangs, check Argo CD UI for cluster connection status..."

# Wait for applications to reach Synced status
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced application/external-cluster-app -n argocd --timeout=300s
kubectl wait --for=jsonpath='{.status.sync.status}'=Synced application/webhook-test-external -n argocd --timeout=300s

kubectl get applications -n argocd

# Verify resources in target cluster
echo "🔍 Verifying resources in target cluster..."
kubectl config use-context kind-target-cluster
kubectl get all -n default
kubectl get all -n guestbook-external
kubectl get examples

kubectl config use-context kind-argocd-cluster

echo ""
echo "🎉 Setup complete!"
echo "=================="
echo ""
echo "📋 Next steps:"
echo "1. Start port forwarding: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "2. Access Argo CD dashboard: http://localhost:8080"
echo "3. Login credentials:"
echo "   Username: admin"
echo "   Password: $ARGOCD_PASSWORD"
echo ""
echo "4. Run './break.sh' to simulate webhook failure"
echo "5. Run './fix.sh' to restore functionality"
echo ""
echo "✅ Baseline established - Argo CD successfully managing external cluster resources"
