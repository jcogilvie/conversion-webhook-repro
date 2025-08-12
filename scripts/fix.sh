#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "� Restoring Conversion Webhook Functionality"
echo "============================================="

# Check what type of failure we created
if [ -f /tmp/webhook-failure-type ]; then
    FAILURE_TYPE=$(cat /tmp/webhook-failure-type)
    echo "� Detected failure type: $FAILURE_TYPE"
else
    echo "⚠️  No failure type detected. Assuming service selector was broken."
    FAILURE_TYPE="no-endpoints"
fi

echo "� Switching to target cluster..."
kubectl config use-context kind-target-cluster

case $FAILURE_TYPE in
    "service-deleted")
        echo "� Recreating webhook service..."
        kubectl apply -f manifests/webhook-deployment.yaml
        ;;
    "no-endpoints")
        echo "� Fixing service selector..."
        kubectl patch service conversion-webhook-service -n webhook-system --type='merge' -p='{"spec":{"selector":{"app":"conversion-webhook"}}}'
        ;;
    *)
        echo "� Attempting to fix service selector..."
        kubectl patch service conversion-webhook-service -n webhook-system --type='merge' -p='{"spec":{"selector":{"app":"conversion-webhook"}}}'
        ;;
esac

echo "⏳ Waiting for webhook pod to be ready..."
kubectl wait --for=condition=ready pod -l app=conversion-webhook -n webhook-system --timeout=60s

echo "✅ Verifying webhook functionality in target cluster..."
kubectl get svc -n webhook-system
kubectl get endpoints conversion-webhook-service -n webhook-system
kubectl get examples.v1.conversion.example.com
kubectl apply -f manifests/test-resources.yaml

echo "� Switching to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

echo "♻️  Restarting Argo CD components to clear error states..."
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd
kubectl rollout restart statefulset/argocd-application-controller -n argocd

echo "⏳ Waiting for restarts to complete..."
kubectl rollout status deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
kubectl rollout status statefulset/argocd-application-controller -n argocd

echo "� Triggering application resync..."
kubectl patch application external-cluster-app -n argocd --type='merge' -p='{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' || true
kubectl patch application cluster-discovery-trigger -n argocd --type='merge' -p='{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' || true

echo "⏳ Waiting a moment for sync to complete..."
sleep 10

echo "✅ Checking application recovery..."
kubectl get applications -n argocd

# Clean up temp file
rm -f /tmp/webhook-failure-type

echo ""
echo "� Webhook restoration complete!"
echo "================================"
echo ""
echo "✅ Verification steps:"
echo "1. Check Argo CD Dashboard: http://localhost:8080 (if port-forward is running)"
echo "2. Application status: kubectl get applications -n argocd"
echo "3. Target cluster resources:"
echo "   kubectl config use-context kind-target-cluster"
echo "   kubectl get examples"
echo "   kubectl get all -n guestbook-external"
echo ""
echo "� Applications should return to healthy/synced status"
echo "� If applications still show errors, wait a few minutes and check again"
