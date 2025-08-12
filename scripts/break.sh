#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "💥 Breaking Conversion Webhook to Simulate Failure"
echo "=================================================="

# Get target server URL using Docker network IP (same logic as setup.sh)
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

echo "🎯 Switching to target cluster..."
kubectl config use-context kind-target-cluster

echo "🗑️  Simulating Crossplane provider upgrade scenario..."
echo "     (This mimics what happened in the real incident)"

# Delete the ProviderRevision that owns the CRD (simulating provider upgrade/rename)
echo "📦 Deleting ProviderRevision (simulating provider removal/rename)..."
kubectl delete providerrevision example-provider-revision-12345 -n webhook-system || echo "ProviderRevision already deleted"

echo "🔍 Checking CRD owner references (should now be orphaned)..."
kubectl get crd examples.conversion.example.com -o yaml | grep -A 10 ownerReferences || echo "No owner references found"

echo "🚫 Choose additional failure method:"
echo "  1) Delete webhook service (complete unavailability)"
echo "  2) Break service selector (no endpoints available)"
echo "  3) Only orphan ProviderRevision (keep webhook working)"
read -p "Enter choice (1, 2, or 3): " choice

case $choice in
    1)
        echo "🗑️  Deleting webhook service..."
        kubectl delete service conversion-webhook-service -n webhook-system
        kubectl get svc -n webhook-system
        FAILURE_TYPE="service-deleted"
        ;;
    2)
        echo "🔧 Breaking service selector..."
        kubectl patch service conversion-webhook-service -n webhook-system --type='merge' -p='{"spec":{"selector":{"app":"non-existent-app"}}}'
        kubectl get svc -n webhook-system
        kubectl get endpoints conversion-webhook-service -n webhook-system
        FAILURE_TYPE="no-endpoints"
        ;;
    3)
        echo "📦 Only orphaning ProviderRevision (webhook still works)..."
        FAILURE_TYPE="orphaned-only"
        ;;
    *)
        echo "❌ Invalid choice. Using option 2 (break selector)..."
        kubectl patch service conversion-webhook-service -n webhook-system --type='merge' -p='{"spec":{"selector":{"app":"non-existent-app"}}}'
        kubectl get svc -n webhook-system
        kubectl get endpoints conversion-webhook-service -n webhook-system
        FAILURE_TYPE="no-endpoints"
        ;;
esac

# Save failure type for fix script
echo $FAILURE_TYPE > /tmp/webhook-failure-type

echo "🔄 Switching to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

echo "🎯 Creating cluster discovery trigger application..."
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g" manifests/cluster-discovery-trigger.yaml | kubectl apply -f -

echo "💥 Forcing cluster re-discovery by removing and re-adding cluster registration..."
echo "    (This simulates the scenario where Argo CD tries to connect to a broken cluster)"

# Delete the cluster registration
echo "🗑️  Removing cluster registration from Argo CD..."
kubectl delete secret target-cluster-secret -n argocd || echo "Cluster secret already deleted"

# Wait a moment for Argo CD to notice the cluster is gone
echo "⏳ Waiting for Argo CD to notice cluster removal..."
sleep 10

# Re-add the cluster registration with the same broken state
echo "🔄 Re-registering cluster (with broken CRDs and orphaned ownership)..."
kubectl config use-context kind-target-cluster
TOKEN=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.token}' | base64 -d)
CA_CERT=$(kubectl get secret argocd-manager-token -n kube-system -o jsonpath='{.data.ca\.crt}')

kubectl config use-context kind-argocd-cluster
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g; s|TOKEN_PLACEHOLDER|$TOKEN|g; s|CA_CERT_PLACEHOLDER|$CA_CERT|g" manifests/target-cluster-secret.yaml | kubectl apply -f -

echo "🔍 Cluster registration re-added. Argo CD will now try to discover APIs in broken cluster..."

echo "♻️  Restarting Argo CD components to force fresh cluster discovery..."
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart statefulset/argocd-application-controller -n argocd

echo "⏳ Waiting for restarts to complete..."
kubectl rollout status deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd

echo ""
echo "🔥 Webhook failure simulation complete!"
echo "======================================"
echo ""
echo "🔍 Check for failures:"
echo "1. Argo CD Dashboard: http://localhost:8080 (if port-forward is running)"
echo "2. Application status: kubectl get applications -n argocd"
echo "3. Application details: kubectl describe application cluster-discovery-trigger -n argocd"
echo ""
echo "📋 Test direct failures in target cluster:"
echo "   kubectl config use-context kind-target-cluster"
echo "   kubectl apply -f manifests/test-resources.yaml"
echo "   kubectl get examples.v1.conversion.example.com"
echo ""
echo "🛠️  Run './fix.sh' to restore functionality"
echo ""
echo "🔥 Expected errors:"
if [ "$FAILURE_TYPE" = "service-deleted" ]; then
    echo "   - 'service \"conversion-webhook-service\" not found'"
elif [ "$FAILURE_TYPE" = "orphaned-only" ]; then
    echo "   - Potential cluster cache sync failures due to orphaned CRD ownership"
    echo "   - 'failed to sync cluster cache' (global cluster discovery failure)"
else
    echo "   - 'no endpoints available for service' or 'connect: connection refused'"
fi
echo "   - 'Failed to load target state'"
echo "   - 'failed to sync cluster cache'"
echo ""
echo "🔍 Key difference: CRD now has orphaned owner references to deleted ProviderRevision"
echo "   This simulates the real Crossplane scenario from the incident"
