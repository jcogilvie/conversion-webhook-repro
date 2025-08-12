#!/bin/bash

echo "� Cleaning up Webhook Reproduction Environment"
echo "==============================================="

# Delete Kind clusters (this removes everything)
echo "� Deleting Kind clusters..."
kind delete cluster --name argocd-cluster 2>/dev/null || echo "  argocd-cluster already deleted or doesn't exist"
kind delete cluster --name target-cluster 2>/dev/null || echo "  target-cluster already deleted or doesn't exist"

# Clean up temporary files
echo "�️  Cleaning up temporary files..."
rm -rf /tmp/webhook-certs 2>/dev/null || true
rm -f /tmp/webhook-failure-type 2>/dev/null || true

echo ""
echo "� Cleanup complete!"
echo "==================="
echo ""
echo "✅ All resources have been removed:"
echo "   - Kind clusters deleted (all pods, services, etc. removed automatically)"
echo "   - Temporary files cleaned up"
echo "   - Ready for fresh setup"
