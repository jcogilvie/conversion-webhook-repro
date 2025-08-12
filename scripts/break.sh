#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "� Breaking Conversion Webhook to Simulate Failure"
echo "=================================================="

# Get target server URL using Docker network IP (same logic as setup.sh)
echo "� Getting target cluster connection details..."
TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
echo "� Raw target server URL: $TARGET_SERVER_RAW"

# Extract port from the localhost URL
TARGET_PORT=$(echo $TARGET_SERVER_RAW | sed 's/.*://')
echo "� Target cluster port: $TARGET_PORT"

# Get the Docker container IP for the target cluster
TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
echo "� Target cluster Docker IP: $TARGET_CONTAINER_IP"

# Construct the target server URL using Docker network IP
TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"
echo "� Target server URL for Argo CD: $TARGET_SERVER"

echo "� Switching to target cluster..."
kubectl config use-context kind-target-cluster

echo "� Choose failure method:"
echo "  1) Delete webhook service (complete unavailability)"
echo "  2) Break service selector (no endpoints available)"
read -p "Enter choice (1 or 2): " choice

case $choice in
    1)
        echo "�️  Deleting webhook service..."
        kubectl delete service conversion-webhook-service -n webhook-system
        kubectl get svc -n webhook-system
        FAILURE_TYPE="service-deleted"
        ;;
    2)
        echo "� Breaking service selector..."
        kubectl patch service conversion-webhook-service -n webhook-system --type='merge' -p='{"spec":{"selector":{"app":"non-existent-app"}}}'
        kubectl get svc -n webhook-system
        kubectl get endpoints conversion-webhook-service -n webhook-system
        FAILURE_TYPE="no-endpoints"
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

echo "� Switching to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

echo "� Creating cluster discovery trigger application..."
sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g" manifests/cluster-discovery-trigger.yaml | kubectl apply -f -

echo "♻️  Restarting Argo CD components to force cache refresh..."
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart statefulset/argocd-application-controller -n argocd

echo "⏳ Waiting for restarts to complete..."
kubectl rollout status deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd

echo ""
echo "� Webhook failure simulation complete!"
echo "======================================"
echo ""
echo "� Check for failures:"
echo "1. Argo CD Dashboard: http://localhost:8080 (if port-forward is running)"
echo "2. Application status: kubectl get applications -n argocd"
echo "3. Application details: kubectl describe application cluster-discovery-trigger -n argocd"
echo ""
echo "� Test direct failures in target cluster:"
echo "   kubectl config use-context kind-target-cluster"
echo "   kubectl apply -f manifests/test-resources.yaml"
echo "   kubectl get examples.v1.conversion.example.com"
echo ""
echo "�️  Run './fix.sh' to restore functionality"
echo ""
echo "� Expected errors:"
if [ "$FAILURE_TYPE" = "service-deleted" ]; then
    echo "   - 'service \"conversion-webhook-service\" not found'"
else
    echo "   - 'no endpoints available for service' or 'connect: connection refused'"
fi
echo "   - 'Failed to load target state'"
echo "   - 'failed to sync cluster cache'"
