#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "🚀 Setting up CRD Evolution Webhook Failure Reproduction"
echo "========================================================"

# Step 1: Create two Kind clusters
echo "📦 Creating Kind clusters..."
kind create cluster --name argocd-cluster
kind create cluster --name target-cluster

# Step 2: Install Argo CD in management cluster FIRST
echo "🎛️  Installing Argo CD..."
kubectl config use-context kind-argocd-cluster
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
kubectl create namespace argocd
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server.insecure"=true \
  --version 8.5.8
#--version 7.6.10

echo "⏳ Waiting for Argo CD server to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s

# Step 3: Apply Argo CD self-management immediately after server is ready
echo "🎛️  Setting up Argo CD self-management (so you can track Argo's status)..."
kubectl apply -f manifests/argocd.yaml

echo "⏳ Waiting for Argo CD repo server to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-repo-server -n argocd --timeout=300s

echo "⏳ Waiting for Argo CD application controller to be ready..."
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-application-controller -n argocd --timeout=300s

echo "✅ All Argo CD components are ready"

# Step 4: Get Argo CD password for later use
echo "🔑 Getting Argo CD credentials..."
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

echo "⏳ Waiting for Argo CD self-management application to appear..."
sleep 10
kubectl get application argocd -n argocd || echo "Self-management app will appear shortly"

# Step 5: Verify Argo CD is fully operational and self-managing
echo "🔍 Verifying Argo CD is fully operational and self-managing..."
kubectl get pods -n argocd
kubectl get applications -n argocd

# Brief test of Argo CD functionality
echo "📊 Testing Argo CD API responsiveness..."
kubectl port-forward svc/argocd-server -n argocd 8081:443 &
PORTFORWARD_PID=$!
sleep 5

# Test if we can reach the API (basic connectivity test)
if curl -k -s https://localhost:8081/api/v1/session > /dev/null; then
    echo "✅ Argo CD API is responsive"
else
    echo "⚠️  Argo CD API not responsive yet - continuing anyway"
fi

# Stop the port forward
kill $PORTFORWARD_PID 2>/dev/null || true

echo "✅ Argo CD is ready and self-managing"
echo ""
echo "🎯 You can now access Argo CD to track its own status:"
echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
echo "   http://localhost:8080 - Username: admin, Password: $ARGOCD_PASSWORD"
echo ""

# Step 6: Setup target cluster with initial CRD (no conversion webhook)
echo "🎯 Setting up target cluster with initial CRD..."
kubectl config use-context kind-target-cluster
kubectl create namespace webhook-system

echo "📋 Creating initial CRD without conversion webhook..."
kubectl apply -f manifests/crd-no-conversion.yaml

echo "✅ Verifying initial CRD works with both API versions..."
kubectl get crd examples.conversion.example.com

# Test that both API versions work without conversion
echo "📋 Creating test resources in both API versions..."
kubectl apply -f manifests/test-resources.yaml

echo "🔍 Verifying both versions work without conversion webhook..."
kubectl get examples
kubectl get examples.v1.conversion.example.com
kubectl get examples.v2.conversion.example.com

echo "✅ Both API versions working correctly without conversion webhook"

# Step 7: Add target cluster to Argo CD
echo "🔗 Registering target cluster with Argo CD..."

# Get the target cluster server URL using Docker network IP
echo "🔍 Getting target cluster connection details..."
TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
TARGET_PORT=$(echo $TARGET_SERVER_RAW | sed 's/.*://')
TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"

# Create service account and token for Argo CD access
kubectl create serviceaccount argocd-manager -n kube-system
kubectl create clusterrolebinding argocd-manager-binding --clusterrole=cluster-admin --serviceaccount=kube-system:argocd-manager
kubectl apply -f manifests/argocd-manager-token.yaml

TOKEN=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
CA_CERT=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.ca\.crt}')

# Register cluster with Argo CD
kubectl config use-context kind-argocd-cluster
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g; s|TOKEN_PLACEHOLDER|$TOKEN|g; s|CA_CERT_PLACEHOLDER|$CA_CERT|g" manifests/target-cluster-secret.yaml | kubectl apply -f -

# Step 8: Create cross-cluster applications
echo "📱 Creating cross-cluster applications..."
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g" manifests/external-cluster-applications.yaml | kubectl apply -f -

echo "⏳ Waiting for applications to be created and initial sync to start..."
sleep 15

echo "🔍 Checking application status (may take a few minutes to sync)..."
kubectl get applications -n argocd

echo "⏳ Waiting up to 5 minutes for applications to sync..."
echo "If this times out, applications may need manual refresh in the UI..."

# Use a more flexible wait that doesn't hang indefinitely
timeout 300s bash -c '
    while true; do
        synced_count=$(kubectl get applications -n argocd -o jsonpath="{range .items[*]}{.status.sync.status}{'\''\\n'\''}{end}" | grep -c "Synced" || echo "0")
        total_count=$(kubectl get applications -n argocd --no-headers | wc -l)
        echo "Applications synced: $synced_count/$total_count"

        if [ "$synced_count" -ge 2 ]; then
            echo "✅ At least 2 applications synced successfully"
            break
        fi

        sleep 15
    done
' || echo "⚠️  Timeout waiting for sync - this is normal, applications may still be syncing"

echo ""
echo "📊 Current application status:"
kubectl get applications -n argocd

# Verify resources in target cluster
echo "🔍 Verifying resources in target cluster..."
kubectl config use-context kind-target-cluster
kubectl get all -n default
kubectl get examples

kubectl config use-context kind-argocd-cluster

echo ""
echo "🎉 Initial setup complete!"
echo "=========================="
echo ""
echo "📋 Current state:"
echo "✅ Argo CD installed and fully operational (including self-management)"
echo "✅ CRD has two API versions (v1 storage, v2 served) without conversion webhook"
echo "✅ Resources created in both API versions work correctly"
echo "✅ Target cluster registered with Argo CD"
echo "✅ Cross-cluster applications created"
echo ""
echo "⚠️  If applications show connection errors, try:"
echo "   kubectl rollout restart deployment/argocd-repo-server -n argocd"
echo "   kubectl rollout restart statefulset/argocd-application-controller -n argocd"
echo ""
echo "📋 Next steps:"
echo "1. Start port forwarding: kubectl port-forward svc/argocd-server -n argocd 8080:443"
echo "2. Access Argo CD dashboard: http://localhost:8080"
echo "3. Login credentials:"
echo "   Username: admin"
echo "   Password: $ARGOCD_PASSWORD"
echo ""
echo "4. Wait for applications to sync in the UI (may take a few minutes)"
echo "5. Once applications are synced, run './scripts/break.sh'"
echo "6. Run './scripts/fix.sh' to restore functionality"
echo ""
echo "✅ Baseline setup complete - ready for CRD evolution webhook failure simulation"
