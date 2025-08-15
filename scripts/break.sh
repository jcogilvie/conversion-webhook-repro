#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "🔥 Simulating CRD Evolution with Broken Conversion Webhook"
echo "=========================================================="

echo "📋 Current scenario:"
echo "• CRD has v1 (storage) and v2 (served) without conversion webhook"
echo "• Resources exist in both API versions"
echo "• Argo CD is managing applications successfully"
echo ""
echo "🎯 Simulation: Adding conversion webhook pointing to non-existent service"
echo "This mimics real-world scenarios where:"
echo "• CRDs evolve to add conversion webhooks"
echo "• Webhook services become unavailable after CRD update"
echo "• Existing resources become inaccessible due to conversion failures"

echo ""
echo "🎯 Switching to target cluster..."
kubectl config use-context kind-target-cluster

echo "📋 Step 1: Verify current state - resources accessible in both API versions"
echo "(Before removing webhook service and applying broken CRD)"
echo "V1 resources:"
kubectl get examples.v1.conversion.example.com || echo "⚠️ V1 API already broken - continuing with break process"
echo ""
echo "V2 resources:"
kubectl get examples.v2.conversion.example.com || echo "⚠️ V2 API already broken - continuing with break process"
echo ""

echo "🔄 Switching back to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

echo "🗑️  Step 2: Remove webhook service application if it exists"
echo "This simulates the webhook service being unavailable/deleted"

# Check if the application exists before trying to delete it
if kubectl get application webhook-service-app -n argocd >/dev/null 2>&1; then
  echo "📱 Webhook service application found, deleting..."
  kubectl delete application webhook-service-app -n argocd

  echo "⏳ Waiting for application deletion to complete (due to finalizers)..."
  # Wait for the application to be completely removed
  while kubectl get application webhook-service-app -n argocd >/dev/null 2>&1; do
    echo "   Application still exists, waiting for finalizer cleanup..."
    sleep 5
  done
  echo "✅ Webhook service application completely removed"

  echo "⏳ Waiting for Argo CD to clean up webhook service resources in target cluster..."
  # Give Argo CD a moment to process the deletion and clean up resources
  sleep 5
else
  echo "✅ Webhook service app doesn't exist (expected for first run)"
fi

echo ""
# Verify the webhook service is gone from target cluster
kubectl config use-context kind-target-cluster
echo "🔍 Verifying webhook service removal..."
kubectl get svc conversion-webhook-service -n webhook-system && echo "⚠️ Service still exists" || echo "✅ Webhook service removed"
kubectl get pods -l app=conversion-webhook -n webhook-system && echo "⚠️ Pods still exist" || echo "✅ Webhook pods removed"

echo "📋 Step 3: Apply CRD evolution - adding broken conversion webhook"
echo "This simulates a CRD update that adds conversion webhook but the service is unavailable"
kubectl apply -f manifests/crd-with-broken-webhook.yaml || echo "⚠️ CRD may already be in broken state"

echo "✅ CRD updated with conversion webhook pointing to non-existent service"

echo ""
echo "📋 Step 4: Test direct impact on target cluster"
echo "Attempting to access resources should now fail due to broken conversion webhook..."

echo ""
echo "🔍 Testing v1 API access (should fail):"
kubectl get examples.v1.conversion.example.com || echo "❌ V1 API access failed as expected"

echo ""
echo "🔍 Testing v2 API access (should fail):"
kubectl get examples.v2.conversion.example.com || echo "❌ V2 API access failed as expected"

echo ""
echo "🔍 Testing generic API access (should fail):"
kubectl get examples || echo "❌ Generic API access failed as expected"

echo ""
echo "🔄 Step 5: Switch to Argo CD cluster and trigger cache invalidation"
kubectl config use-context kind-argocd-cluster

echo "📱 Step 6: Force Argo CD to refresh target cluster cache"
echo "This simulates Argo CD discovering the broken CRD state..."

# Get the target server URL and encode it for the API call
TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"

# Double URL encode the target server for the API call
DOUBLE_ENCODED_SERVER=$(echo "$TARGET_SERVER" | sed 's/:/%253A/g' | sed 's/\//%252F/g')

echo "🔄 Method 1: Invalidate cluster cache via Argo CD API (with authentication)"
echo "Using cluster: $TARGET_SERVER"

echo "🔍 Checking Argo CD API connectivity..."
if curl -k -s --connect-timeout 3 "https://localhost:8080/api/version" > /dev/null 2>&1; then
  echo "✅ Argo CD API is accessible at localhost:8080"

  # Get the admin password from the Kubernetes secret
  ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

  # First, login to get a session token
  echo "🔐 Authenticating with Argo CD..."

  # Create JSON payload properly
  JSON_PAYLOAD=$(printf '{"username":"admin","password":"%s"}' "$ADMIN_PASSWORD")

  # Try authentication using HTTPS
  echo "🔄 Attempting login via HTTPS..."
  LOGIN_RESPONSE=$(curl -k -s -X POST \
    "https://localhost:8080/api/v1/session" \
    -H "Content-Type: application/json" \
    -d "$JSON_PAYLOAD" \
    2>/dev/null || echo 'CURL_FAILED')

  # Check if login was successful and extract token
  if echo "$LOGIN_RESPONSE" | grep -q '"token"'; then
    TOKEN=$(echo "$LOGIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

    if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
      echo "✅ Authentication successful"

      # Now call the cache invalidation API with the token
      echo "🔄 Calling cache invalidation API..."
      RESPONSE=$(curl -k -s -L -X POST \
        "https://localhost:8080/api/v1/clusters/$DOUBLE_ENCODED_SERVER/invalidate-cache" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d '{}' \
        2>/dev/null || echo "CACHE_INVALIDATION_FAILED")

      if [[ "$RESPONSE" == *"CACHE_INVALIDATION_FAILED"* ]]; then
        echo "⚠️ Cache invalidation API call failed"
      else
        echo "✅ Cache invalidation successful"

        # Parse the response to check cluster connection state
        if echo "$RESPONSE" | grep -q '"status":"Failed"'; then
          CONNECTION_MESSAGE=$(echo "$RESPONSE" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
          if echo "$CONNECTION_MESSAGE" | grep -q "conversion-webhook-service.*not found"; then
            echo "🎯 Confirmed: Argo CD detected the broken conversion webhook"
            echo "   Error: conversion webhook service not found"
          elif echo "$CONNECTION_MESSAGE" | grep -q "conversion webhook.*failed"; then
            echo "🎯 Confirmed: Argo CD detected conversion webhook failure"
          else
            echo "🔍 Cluster connection failed for different reason:"
            echo "   $(echo "$CONNECTION_MESSAGE" | sed 's/\\"/"/g')"
          fi
        else
          echo "⚠️ Expected cluster connection failure but cluster appears healthy"
          echo "   The webhook break may not have taken effect yet"
        fi
      fi
    else
      echo "⚠️ Could not extract token from login response"
    fi
  else
    echo "⚠️ Login failed or invalid response"
    echo ""
    echo "🔍 Debugging steps:"
    echo "1. Verify port-forward is working: curl -k https://localhost:8080/api/version"
    echo "2. Check admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
    echo "3. Test manual login via UI: https://localhost:8080"
    echo "4. Manual curl test: curl -k -X POST https://localhost:8080/api/v1/session -H 'Content-Type: application/json' -d '{\"username\":\"admin\",\"password\":\"YOURPASSWORD\"}'"
  fi
else
  echo "⚠️ Argo CD API not accessible at localhost:8080"
  echo "💡 To enable API access, run in another terminal:"
  echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
  echo ""
  echo "🔄 Alternative: Manual cache invalidation via UI"
  ENCODED_TARGET_SERVER=$(echo "$TARGET_SERVER" | sed 's/:/%3A/g' | sed 's/\//%2F/g')
  echo "   1. Start port-forward: kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
  echo "   2. Access Argo CD: https://localhost:8080"
  echo "   3. Navigate to cluster settings: https://localhost:8080/settings/clusters/$ENCODED_TARGET_SERVER"
  echo "   4. Click 'Invalidate Cache' button"
  echo ""
  echo "📋 For now, continuing with application refresh method..."
fi

echo ""
echo "🔄 Method 2: Force application refresh (triggers cache rebuild)"
kubectl patch application external-cluster-app -n argocd --type='merge' -p='{"operation":{"initiatedBy":{"username":"admin"},"info":[{"name":"reason","value":"force-refresh-after-crd-evolution"}]}}' || echo "Patch failed - this is expected"

echo ""
echo "📊 Step 7: Check application status for cluster-wide failure"
echo "All applications targeting the cluster should now show errors..."

kubectl get applications -n argocd

echo ""
echo "🔥 CRD Evolution Webhook Failure Complete!"
echo "==========================================="
echo ""
echo "🎯 What just happened:"
echo "1. ✅ Checked current state (may have been already broken - script continues)"
echo "2. 🗑️  Removed webhook service application (simulating service unavailability)"
echo "3. 🔥 Updated CRD to add conversion webhook pointing to non-existent service"
echo "4. 💥 All API access to the CRD now fails due to broken webhook"
echo "5. 🌊 Argo CD cache refresh discovers the broken state"
echo "6. ❌ ALL applications in target cluster should now show errors"
echo ""
echo "🧠 Key Mechanism: v1 is storage version, v2 is served"
echo "   • When Argo CD accesses any CRD resource, Kubernetes must convert"
echo "   • from v1 (storage) to v2 (served) or vice versa"
echo "   • This triggers the conversion webhook for EVERY resource access"
echo "   • With webhook broken, ALL CRD operations fail cluster-wide"
echo ""
echo "🔍 Check for the target error patterns:"
echo "kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=50"
echo ""
echo "📱 Check application status:"
echo "kubectl get applications -n argocd"
echo "kubectl describe application external-cluster-app -n argocd"
echo ""
echo "🌐 Check Argo CD UI (if port-forward is running):"
echo "https://localhost:8080 - all apps targeting the cluster should be 'Unknown' status"
echo ""
echo "🔍 Expected error patterns:"
echo "- 'Failed to load target state'"
echo "- 'conversion webhook for conversion.example.com/v1, Kind=Example failed'"
echo "- 'service \"conversion-webhook-service\" not found'"
echo "- Applications show 'Unknown' health status"
echo ""
echo "🔄 Script is idempotent - can be run multiple times safely"
echo "🛠️  Run './scripts/fix.sh' to restore functionality via Argo"
