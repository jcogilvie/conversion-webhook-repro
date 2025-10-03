#!/bin/bash
set -e

echo "🔄 Cross-Namespace Ownership Test Setup"
echo "========================================"
echo ""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Save the initial context to restore later
INITIAL_CONTEXT=$(kubectl config current-context)
echo "Current context: $INITIAL_CONTEXT"

# Configuration
APP_NAME="cross-namespace-test"
APP_NAMESPACE="argocd"
TARGET_NAMESPACE="default"
OTHER_NAMESPACE="cross-namespace-test"
CLUSTER_ROLE_NAME="test-cluster-role"

# Cleanup function to restore context on exit
cleanup() {
    if [[ "$(kubectl config current-context)" != "$INITIAL_CONTEXT" ]]; then
        echo ""
        echo "Restoring initial context: $INITIAL_CONTEXT"
        kubectl config use-context "$INITIAL_CONTEXT" >/dev/null 2>&1
    fi
}

# Set trap to ensure cleanup runs on exit
trap cleanup EXIT

# Function to check if we're on the correct context
check_context() {
    local expected_context=$1
    local current_context=$(kubectl config current-context)
    if [[ "$current_context" != "$expected_context" ]]; then
        echo -e "${YELLOW}Switching to context: $expected_context${NC}"
        kubectl config use-context "$expected_context"
    else
        echo -e "${GREEN}Already on context: $expected_context${NC}"
    fi
}

# Function to wait for resource
wait_for_resource() {
    local resource_type=$1
    local resource_name=$2
    local namespace=$3
    local max_attempts=30
    local attempt=0

    echo "⏳ Waiting for $resource_type/$resource_name to be created..."

    while [[ $attempt -lt $max_attempts ]]; do
        if kubectl get "$resource_type" "$resource_name" ${namespace:+-n "$namespace"} >/dev/null 2>&1; then
            echo -e "${GREEN}✓ $resource_type/$resource_name is ready${NC}"
            return 0
        fi
        sleep 2
        ((attempt++))
    done

    echo -e "${RED}✗ Timeout waiting for $resource_type/$resource_name${NC}"
    return 1
}

# Step 1: Create the Argo CD application
echo "📱 Step 1: Creating Argo CD Application"
echo "----------------------------------------"
check_context "kind-argocd-cluster"

# Check if app already exists
if kubectl get application "$APP_NAME" -n "$APP_NAMESPACE" >/dev/null 2>&1; then
    echo -e "${YELLOW}Application $APP_NAME already exists. Deleting...${NC}"
    kubectl delete application "$APP_NAME" -n "$APP_NAMESPACE"
    sleep 2
fi

# Create the application pointing to GitHub repo
echo "Creating application: $APP_NAME"
cat <<EOF | kubectl apply -f -
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: $APP_NAME
  namespace: $APP_NAMESPACE
spec:
  project: default
  source:
    repoURL: 'https://github.com/jcogilvie/conversion-webhook-repro.git'
    path: cross-namespace-test
    targetRevision: HEAD
  destination:
    server: https://kubernetes.default.svc
    namespace: $TARGET_NAMESPACE
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
EOF

echo -e "${GREEN}✓ Application created${NC}"

# Step 2: Sync the application
echo ""
echo "🔄 Step 2: Syncing Application"
echo "-------------------------------"
echo "Triggering sync..."
kubectl patch application "$APP_NAME" -n "$APP_NAMESPACE" --type merge -p '{"operation":{"sync":{"revision":"HEAD"}}}'

# Wait for sync to complete
echo "Waiting for sync to complete..."
sleep 5

# Check sync status
SYNC_STATUS=$(kubectl get application "$APP_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
HEALTH_STATUS=$(kubectl get application "$APP_NAME" -n "$APP_NAMESPACE" -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

echo "Sync Status: $SYNC_STATUS"
echo "Health Status: $HEALTH_STATUS"

# Step 3: Switch to target cluster and get ClusterRole UID
echo ""
echo "🎯 Step 3: Getting ClusterRole UID from Target Cluster"
echo "-------------------------------------------------------"
check_context "kind-target-cluster"

# Wait for ClusterRole to be created
wait_for_resource "clusterrole" "$CLUSTER_ROLE_NAME" ""

# Get the ClusterRole UID
CLUSTER_ROLE_UID=$(kubectl get clusterrole "$CLUSTER_ROLE_NAME" -o jsonpath='{.metadata.uid}')
if [[ -z "$CLUSTER_ROLE_UID" ]]; then
    echo -e "${RED}✗ Failed to get ClusterRole UID${NC}"
    exit 1
fi

echo -e "${GREEN}✓ ClusterRole UID: $CLUSTER_ROLE_UID${NC}"

# Step 4: Create the other namespace if it doesn't exist
echo ""
echo "📁 Step 4: Creating Test Namespace"
echo "-----------------------------------"
if ! kubectl get namespace "$OTHER_NAMESPACE" >/dev/null 2>&1; then
    echo "Creating namespace: $OTHER_NAMESPACE"
    kubectl create namespace "$OTHER_NAMESPACE"
else
    echo -e "${YELLOW}Namespace $OTHER_NAMESPACE already exists${NC}"
fi

# Step 5: Create Roles with ownerReferences
echo ""
echo "👶 Step 5: Creating Child Roles with Owner References"
echo "------------------------------------------------------"

# Create Role in the default namespace
echo "Creating Role in namespace: $TARGET_NAMESPACE"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: test-role-same-ns
  namespace: $TARGET_NAMESPACE
  ownerReferences:
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    name: $CLUSTER_ROLE_NAME
    uid: $CLUSTER_ROLE_UID
rules:
- apiGroups: [""]
  resources: ["configmaps"]
  verbs: ["get", "list"]
EOF

echo -e "${GREEN}✓ Role created in $TARGET_NAMESPACE${NC}"

# Create Role in the other namespace
echo "Creating Role in namespace: $OTHER_NAMESPACE"
cat <<EOF | kubectl apply -f -
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: test-role-other-ns
  namespace: $OTHER_NAMESPACE
  ownerReferences:
  - apiVersion: rbac.authorization.k8s.io/v1
    kind: ClusterRole
    name: $CLUSTER_ROLE_NAME
    uid: $CLUSTER_ROLE_UID
rules:
- apiGroups: [""]
  resources: ["secrets"]
  verbs: ["get", "list"]
EOF

echo -e "${GREEN}✓ Role created in $OTHER_NAMESPACE${NC}"

# Step 6: Verify the setup
echo ""
echo "✅ Step 6: Verification"
echo "-----------------------"
echo "Resources created:"
echo "  • ClusterRole: $CLUSTER_ROLE_NAME (UID: $CLUSTER_ROLE_UID)"
echo "  • Role: test-role-same-ns in namespace $TARGET_NAMESPACE"
echo "  • Role: test-role-other-ns in namespace $OTHER_NAMESPACE"
echo ""
echo "Both Roles have ownerReferences pointing to the ClusterRole."
echo ""

# Step 7: Display next steps
echo "📋 Next Steps:"
echo "--------------"
echo "1. Go to Argo CD UI: https://localhost:8080"
echo "2. Navigate to the application: $APP_NAME"
echo "3. Click on the application to view the resource tree"
echo "4. Invalidate the cache to rebuild orphaned children index:"
echo "   - Click on the application"
echo "   - Click on 'Refresh' button with hard refresh option"
echo "   - Or use: Settings → Clusters → TARGET → Invalidate Cache"
echo "5. Check if the Roles appear as children of the ClusterRole in the tree"
echo ""
echo "🎉 Setup complete!"
echo ""
echo "To clean up, run:"
echo "  kubectl delete application $APP_NAME -n $APP_NAMESPACE --context kind-argocd-cluster"
echo "  kubectl delete role test-role-same-ns -n $TARGET_NAMESPACE --context kind-target-cluster"
echo "  kubectl delete role test-role-other-ns -n $OTHER_NAMESPACE --context kind-target-cluster"
echo "  kubectl delete namespace $OTHER_NAMESPACE --context kind-target-cluster"
echo ""
echo "Context restored to: $INITIAL_CONTEXT"