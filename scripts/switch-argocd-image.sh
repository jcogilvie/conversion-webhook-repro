#!/bin/bash
set -e

# Parse command-line arguments
NON_INTERACTIVE=false
TARGET_MODE=""

while [[ "$#" -gt 0 ]]; do
    case $1 in
        -y|--yes) NON_INTERACTIVE=true ;;
        default|conversion-webhook-fix|cluster-scoped-parents) TARGET_MODE="$1" ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

# Define available images
CONVERSION_WEBHOOK_IMAGE="argocd:conversion-webhook-failure-isolation"
CLUSTER_SCOPED_IMAGE="argocd:cluster-scoped-parents"

echo "🔄 Argo CD Image Switcher"
echo "========================"

# Ensure we're in the Argo CD cluster context
echo "🎯 Switching to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

# Check if the Argo CD self-management application exists
if ! kubectl get application argocd -n argocd >/dev/null 2>&1; then
    echo "❌ Argo CD self-management application not found"
    echo "💡 Run './scripts/setup.sh' first to set up the environment"
    exit 1
fi

# Get current image configuration
echo "🔍 Checking current Argo CD image configuration..."
CURRENT_VALUES=$(kubectl get application argocd -n argocd -o jsonpath='{.spec.source.helm.values}' 2>/dev/null || echo "")

# Determine current state
if echo "$CURRENT_VALUES" | grep -q 'tag.*"conversion-webhook-failure-isolation"'; then
    CURRENT_STATE="conversion-webhook-fix"
    CURRENT_IMAGE_DESC="conversion webhook fix image"
elif echo "$CURRENT_VALUES" | grep -q 'tag.*"cluster-scoped-parents"'; then
    CURRENT_STATE="cluster-scoped-parents"
    CURRENT_IMAGE_DESC="cluster-scoped parents image"
else
    CURRENT_STATE="default"
    CURRENT_IMAGE_DESC="default Helm chart image"
fi

echo "📋 Current image: $CURRENT_IMAGE_DESC"
echo ""

# Determine target mode
if [[ -z "$TARGET_MODE" && "$NON_INTERACTIVE" != "true" ]]; then
    # Interactive mode - prompt for selection
    echo "Available images:"
    echo "  1) default                - Use default Helm chart image"
    echo "  2) conversion-webhook-fix - Test conversion webhook failure isolation"
    echo "  3) cluster-scoped-parents - Test cluster-scoped parent relationships"
    echo ""
    read -p "Select target image (1-3): " selection

    case "$selection" in
        1) TARGET_MODE="default" ;;
        2) TARGET_MODE="conversion-webhook-fix" ;;
        3) TARGET_MODE="cluster-scoped-parents" ;;
        *) echo "❌ Invalid selection"; exit 1 ;;
    esac
elif [[ -z "$TARGET_MODE" ]]; then
    echo "❌ Target mode required in non-interactive mode"
    echo "Usage: $0 [-y] [default|conversion-webhook-fix|cluster-scoped-parents]"
    exit 1
fi

# Set target image properties based on mode
case "$TARGET_MODE" in
    default)
        TARGET_IMAGE_TAG=""  # Empty means use default
        TARGET_IMAGE_DESC="default Helm chart image"
        TARGET_LOCAL_IMAGE=""
        ;;
    conversion-webhook-fix)
        TARGET_IMAGE_TAG="conversion-webhook-failure-isolation"
        TARGET_IMAGE_DESC="conversion webhook fix image"
        TARGET_LOCAL_IMAGE="$CONVERSION_WEBHOOK_IMAGE"
        ;;
    cluster-scoped-parents)
        TARGET_IMAGE_TAG="cluster-scoped-parents"
        TARGET_IMAGE_DESC="cluster-scoped parents image"
        TARGET_LOCAL_IMAGE="$CLUSTER_SCOPED_IMAGE"
        ;;
esac

echo "🎯 Target image: $TARGET_IMAGE_DESC"
echo ""

# Check if we need to do anything
if [[ "$CURRENT_STATE" == "$TARGET_MODE" ]]; then
    echo "✅ Already using $TARGET_IMAGE_DESC"
    exit 0
fi

# Confirm the action if not non-interactive
if [[ "$NON_INTERACTIVE" != "true" ]]; then
    read -p "❓ Switch from $CURRENT_IMAGE_DESC to $TARGET_IMAGE_DESC? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "🚫 Operation cancelled"
        exit 0
    fi
fi

# Load custom image into Kind cluster if needed
if [[ -n "$TARGET_LOCAL_IMAGE" ]]; then
    echo "📦 Loading custom image into Kind cluster..."
    if ! docker image inspect "$TARGET_LOCAL_IMAGE" >/dev/null 2>&1; then
        echo "❌ Custom image '$TARGET_LOCAL_IMAGE' not found locally"
        echo "💡 Build the image first with:"
        echo "   docker build -t $TARGET_LOCAL_IMAGE ."
        exit 1
    fi

    kind load docker-image "$TARGET_LOCAL_IMAGE" --name argocd-cluster
    echo "✅ Custom image loaded into Kind cluster"
fi

# Prepare the values override
if [[ -n "$TARGET_IMAGE_TAG" ]]; then
    # Use custom image
    NEW_VALUES=$(cat <<EOF
controller:
  image:
    repository: "argocd"
    tag: "$TARGET_IMAGE_TAG"
    imagePullPolicy: "Never"
server:
  image:
    repository: "argocd"
    tag: "$TARGET_IMAGE_TAG"
    imagePullPolicy: "Never"
EOF
)
    echo "🔧 Configuring Argo CD to use $TARGET_IMAGE_DESC..."
else
    # Use default image
    NEW_VALUES=""
    echo "🔧 Configuring Argo CD to use default Helm chart images..."
fi

# Apply the change to the Argo CD self-management application
echo "📝 Updating Argo CD self-management application..."

# Create a temporary patch file
cat > /tmp/argocd-patch.yaml << EOF
spec:
  source:
    helm:
      values: |
$(echo "$NEW_VALUES" | sed 's/^/        /')
EOF

# Apply the patch
kubectl patch application argocd -n argocd --type='merge' --patch-file /tmp/argocd-patch.yaml

# Clean up temporary file
rm -f /tmp/argocd-patch.yaml

echo "✅ Application updated successfully"

# Wait for sync to start
echo "⏳ Waiting for Argo CD to detect and sync the changes..."
sleep 5

# Monitor the sync status
echo "📊 Monitoring sync progress..."
TIMEOUT=300  # 5 minutes
ELAPSED=0
SYNC_COMPLETED=false

while [[ $ELAPSED -lt $TIMEOUT ]]; do
    SYNC_STATUS=$(kubectl get application argocd -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
    HEALTH_STATUS=$(kubectl get application argocd -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

    echo "   Sync: $SYNC_STATUS | Health: $HEALTH_STATUS"

    if [[ "$SYNC_STATUS" == "Synced" && "$HEALTH_STATUS" == "Healthy" ]]; then
        SYNC_COMPLETED=true
        break
    fi

    sleep 10
    ELAPSED=$((ELAPSED + 10))
done

if [[ "$SYNC_COMPLETED" == "true" ]]; then
    echo "✅ Sync completed successfully!"
else
    echo "⚠️ Sync is taking longer than expected"
    echo "💡 Check the Argo CD dashboard for details: https://localhost:8080"
fi

# Verify the change
echo ""
echo "🔍 Verifying the image change..."

CONTROLLER_IMAGE=$(kubectl get deployment argocd-application-controller -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")
SERVER_IMAGE=$(kubectl get deployment argocd-server -n argocd -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || echo "unknown")

if [[ -n "$TARGET_IMAGE_TAG" ]]; then
    # Verify custom image is in use
    if echo "$CONTROLLER_IMAGE" | grep -q "argocd:$TARGET_IMAGE_TAG"; then
        echo "✅ Application controller is now using $TARGET_IMAGE_DESC: $CONTROLLER_IMAGE"
    else
        echo "⚠️ Application controller image: $CONTROLLER_IMAGE"
        echo "   Custom image may still be rolling out..."
    fi

    if echo "$SERVER_IMAGE" | grep -q "argocd:$TARGET_IMAGE_TAG"; then
        echo "✅ UI server is now using $TARGET_IMAGE_DESC: $SERVER_IMAGE"
    else
        echo "⚠️ UI server image: $SERVER_IMAGE"
        echo "   Custom image may still be rolling out..."
    fi
else
    # Verify default image is in use
    if echo "$CONTROLLER_IMAGE" | grep -q "quay.io/argoproj/argocd"; then
        echo "✅ Application controller is using default image: $CONTROLLER_IMAGE"
    else
        echo "⚠️ Application controller image: $CONTROLLER_IMAGE"
        echo "   Default image may still be rolling out..."
    fi

    if echo "$SERVER_IMAGE" | grep -q "quay.io/argoproj/argocd"; then
        echo "✅ UI server is using default image: $SERVER_IMAGE"
    else
        echo "⚠️ UI server image: $SERVER_IMAGE"
        echo "   Default image may still be rolling out..."
    fi
fi

# Show component status
echo ""
echo "📊 Argo CD Component Status:"
kubectl get pods -n argocd -o custom-columns="NAME:.metadata.name,STATUS:.status.phase,IMAGE:.spec.containers[0].image" | grep -E "(NAME|argocd-)"

echo ""
echo "🎉 Image switch completed!"
echo ""
echo "💡 Next steps:"
echo "1. Verify Argo CD functionality in the dashboard"
echo "2. Test the specific feature for the selected image:"
echo "   - conversion-webhook-fix:  Test webhook failure handling"
echo "   - cluster-scoped-parents:  Test cross-namespace parent-child relationships"
echo "3. Use this script again to switch images as needed"
echo ""
echo "🔄 Usage:"
echo "   ./scripts/switch-argocd-image.sh                            # Interactive mode - prompts for selection"
echo "   ./scripts/switch-argocd-image.sh default                    # Switch to default image"
echo "   ./scripts/switch-argocd-image.sh conversion-webhook-fix     # Switch to conversion webhook fix image"
echo "   ./scripts/switch-argocd-image.sh cluster-scoped-parents     # Switch to cluster-scoped parents image"
echo "   ./scripts/switch-argocd-image.sh -y [image]                 # Non-interactive mode"
echo ""
echo "📱 Access Argo CD: https://localhost:8080 (if port-forward is running)"
