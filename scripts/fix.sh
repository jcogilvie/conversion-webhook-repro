#!/bin/bash
set -e

# Change to project root directory (one level up from scripts)
cd "$(dirname "$0")/.."

echo "🛠️  Restoring CRD Functionality After Evolution Failure"
echo "======================================================="

echo "🎯 Switching to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

echo "🔍 Current broken state:"
echo "• CRD has conversion webhook pointing to non-existent service"
echo "• All API access to the CRD fails"
echo "• Argo CD applications show 'Unknown' status"

echo ""
echo "🛠️  Choose restoration method:"
echo "1) Deploy working conversion webhook service via Argo CD (GitOps approach)"
echo "2) Remove conversion webhook (revert to no-conversion state)"
echo "3) Deploy webhook service directly in target cluster (non-GitOps)"
read -p "Enter choice (1, 2, or 3): " choice

case $choice in
    1)
        echo "🎯 Option 1: Deploying working conversion webhook via Argo CD..."
        echo "This demonstrates GitOps restoration of the webhook service"

        # Get target server details for the application
        TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
        TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
        TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"

        echo "🔨 Building and loading webhook server image..."
        docker build -t webhook-conversion:latest .
        kind load docker-image webhook-conversion:latest --name target-cluster

        echo "🔐 Generating TLS certificates for the webhook..."
        mkdir -p /tmp/webhook-certs
        cd /tmp/webhook-certs

        # Generate CA private key
        openssl genrsa -out ca.key 2048

        # Generate CA certificate
        openssl req -new -x509 -days 365 -key ca.key -out ca.crt -subj "/C=CA/ST=Province/O=Example"

        # Generate server private key
        openssl genrsa -out tls.key 2048

        # Create certificate signing request
        openssl req -new -key tls.key -out server.csr -subj "/C=CA/ST=Province/O=Example" -addext "subjectAltName=DNS:conversion-webhook-service.webhook-system.svc,DNS:conversion-webhook-service.webhook-system.svc.cluster.local"

        # Generate server certificate
        openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out tls.crt -days 365 -extensions v3_req -extfile <(echo -e "[ v3_req ]\nsubjectAltName=DNS:conversion-webhook-service.webhook-system.svc,DNS:conversion-webhook-service.webhook-system.svc.cluster.local")

        kubectl config use-context kind-target-cluster

        # Delete existing secret if it exists to ensure clean state
        kubectl delete secret webhook-certs -n webhook-system || true

        # Create the secret with our newly generated certificates
        kubectl create secret tls webhook-certs \
          --cert=tls.crt \
          --key=tls.key \
          -n webhook-system

        CA_BUNDLE=$(base64 -w 0 < ca.crt)

        # Update CRD with the SAME CA bundle that signed our server certificate
        echo "🔧 Patching CRD with matching CA bundle..."
        kubectl patch crd examples.conversion.example.com --type='merge' -p "{\"spec\":{\"conversion\":{\"webhook\":{\"clientConfig\":{\"caBundle\":\"$CA_BUNDLE\"}}}}}"

        cd -

        # Deploy webhook service directly FIRST to break the chicken-and-egg problem
        echo "🚀 Deploying webhook service directly to break the deadlock..."
        kubectl apply -f webhook-service-managed/resources.yaml

        echo "⏳ Waiting for webhook pod to be ready..."
        kubectl wait --for=condition=ready pod -l app=conversion-webhook -n webhook-system --timeout=120s

        echo "✅ Webhook service is now functional - cluster cache should recover"

        echo "🔄 Switching back to Argo CD cluster..."
        kubectl config use-context kind-argocd-cluster

        # Invalidate cluster cache to speed up recovery
        echo "🔄 Invalidating cluster cache to accelerate recovery..."
        DOUBLE_ENCODED_SERVER=$(echo "$TARGET_SERVER" | sed 's/:/%253A/g' | sed 's/\//%252F/g')

        # Check if port-forward is running by testing connectivity
        if curl -k -s --connect-timeout 3 "https://localhost:8080/api/version" > /dev/null 2>&1; then
          echo "✅ Argo CD API is accessible at localhost:8080"

          # Get the admin password and authenticate
          ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

          LOGIN_RESPONSE=$(curl -k -s -X POST \
            "https://localhost:8080/api/v1/session" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" \
            2>/dev/null || echo '{"error":"LOGIN_FAILED"}')

          if echo "$LOGIN_RESPONSE" | grep -q '"token"'; then
            TOKEN=$(echo "$LOGIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

            if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
              echo "✅ Authentication successful, invalidating cache..."

              CACHE_RESPONSE=$(curl -k -s -L -X POST \
                "https://localhost:8080/api/v1/clusters/$DOUBLE_ENCODED_SERVER/invalidate-cache" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $TOKEN" \
                -d '{}' \
                2>/dev/null || echo "CACHE_INVALIDATION_FAILED")

              if [[ "$CACHE_RESPONSE" == *"CACHE_INVALIDATION_FAILED"* ]]; then
                echo "⚠️ Cache invalidation may have failed - cache will refresh automatically"
              else
                echo "✅ Cache invalidated successfully"

                # Parse the response to check if the cluster is now healthy
                if echo "$CACHE_RESPONSE" | grep -q '"status":"Successful"'; then
                  echo "🎯 Confirmed: Cluster connection restored - webhook is working"
                elif echo "$CACHE_RESPONSE" | grep -q '"status":"Failed"'; then
                  CONNECTION_MESSAGE=$(echo "$CACHE_RESPONSE" | sed -n 's/.*"message":"\([^"]*\)".*/\1/p')
                  if echo "$CONNECTION_MESSAGE" | grep -q "conversion webhook.*failed"; then
                    echo "⚠️ Webhook failure still detected - fix may need more time"
                    echo "   Error: $(echo "$CONNECTION_MESSAGE" | sed 's/\\"/"/g')"
                  else
                    echo "🔍 Different cluster issue detected:"
                    echo "   $(echo "$CONNECTION_MESSAGE" | sed 's/\\"/"/g')"
                  fi
                else
                  echo "📊 Cache invalidated - cluster state will be refreshed on next sync"
                fi
              fi
            else
              echo "⚠️ Could not extract token - cache will refresh automatically"
            fi
          else
            echo "⚠️ Authentication failed - cache will refresh automatically"
          fi
        else
          echo "⚠️ Argo CD API not accessible at localhost:8080"
          echo "💡 To enable API access, run in another terminal:"
          echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
          echo "📋 Cache will refresh automatically when applications sync"
        fi

        # NOW create the Argo CD application for ongoing GitOps management
        echo "📱 Creating Argo CD application for ongoing webhook service management..."

        # Apply the application manifest with substitution
        sed "s|TARGET_SERVER_PLACEHOLDER|$TARGET_SERVER|g" manifests/webhook-service-app.yaml | kubectl apply -f -

        # Provide URL for manual cache invalidation if needed
        ENCODED_TARGET_SERVER=$(echo "$TARGET_SERVER" | sed 's/:/%3A/g' | sed 's/\//%2F/g')
        echo ""
        echo "💡 If this step takes too long, you can manually invalidate the cluster cache:"
        echo "   Argo CD Cluster Page: http://localhost:8080/settings/clusters/$ENCODED_TARGET_SERVER"
        echo "   Click 'Invalidate Cache' button on the cluster page"
        echo ""

        echo "⏳ Waiting for Argo CD to recognize and sync the existing resources..."
        kubectl wait --for=jsonpath='{.status.sync.status}'=Synced application/webhook-service-app -n argocd --timeout=120s || echo "⚠️ App may take time to sync - resources are already deployed"
        ;;

    2)
        echo "🔄 Option 2: Reverting CRD to no-conversion state..."
        kubectl config use-context kind-target-cluster
        kubectl apply -f manifests/crd-no-conversion.yaml
        echo "✅ CRD reverted to no-conversion state"
        
        echo "🔄 Switching back to Argo CD cluster..."
        kubectl config use-context kind-argocd-cluster
        
        # Get target server details for cache invalidation
        TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
        TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
        TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"
        
        # Invalidate cluster cache to speed up recovery
        echo "🔄 Invalidating cluster cache to accelerate recovery..."
        DOUBLE_ENCODED_SERVER=$(echo "$TARGET_SERVER" | sed 's/:/%253A/g' | sed 's/\//%252F/g')

        # Check if port-forward is running by testing connectivity
        if curl -k -s --connect-timeout 3 "https://localhost:8080/api/version" > /dev/null 2>&1; then
          echo "✅ Argo CD API is accessible at localhost:8080"

          # Get the admin password and authenticate
          ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

          LOGIN_RESPONSE=$(curl -k -s -X POST \
            "https://localhost:8080/api/v1/session" \
            -H "Content-Type: application/json" \
            -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASSWORD\"}" \
            2>/dev/null || echo '{"error":"LOGIN_FAILED"}')

          if echo "$LOGIN_RESPONSE" | grep -q '"token"'; then
            TOKEN=$(echo "$LOGIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

            if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
              echo "✅ Authentication successful, invalidating cache..."

              CACHE_RESPONSE=$(curl -k -s -L -X POST \
                "https://localhost:8080/api/v1/clusters/$DOUBLE_ENCODED_SERVER/invalidate-cache" \
                -H "Content-Type: application/json" \
                -H "Authorization: Bearer $TOKEN" \
                -d '{}' \
                2>/dev/null || echo "CACHE_INVALIDATION_FAILED")

              if [[ "$CACHE_RESPONSE" == *"CACHE_INVALIDATION_FAILED"* ]]; then
                echo "⚠️ Cache invalidation may have failed - cache will refresh automatically"
              else
                echo "✅ Cache invalidated successfully"
              fi
            else
              echo "⚠️ Could not extract token - cache will refresh automatically"
            fi
          else
            echo "⚠️ Authentication failed - cache will refresh automatically"
          fi
        else
          echo "⚠️ Argo CD API not accessible at localhost:8080"
          echo "💡 To enable API access, run in another terminal:"
          echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
          echo "📋 Cache will refresh automatically when applications sync"
        fi
        ;;

    3)
        echo "🔧 Option 3: Deploy webhook directly in target cluster..."
        kubectl config use-context kind-target-cluster

        # Build and load image
        docker build -t webhook-conversion:latest .
        kind load docker-image webhook-conversion:latest --name target-cluster

        # Generate certificates and deploy webhook
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
          -n webhook-system --dry-run=client -o yaml | kubectl apply -f -

        CA_BUNDLE=$(base64 -w 0 < ca.crt)

        # Update CRD with correct CA bundle
        kubectl patch crd examples.conversion.example.com --type='merge' -p "{\"spec\":{\"conversion\":{\"webhook\":{\"clientConfig\":{\"caBundle\":\"$CA_BUNDLE\"}}}}}"

        # Deploy webhook using the existing GitOps manifest directly
        kubectl apply -f webhook-service-managed/resources.yaml

        cd -
        echo "⏳ Waiting for webhook pod to be ready..."
        kubectl wait --for=condition=ready pod -l app=conversion-webhook -n webhook-system --timeout=120s
        ;;

    *)
        echo "❌ Invalid choice. Using option 2 (revert to no-conversion)..."
        kubectl config use-context kind-target-cluster
        kubectl apply -f manifests/crd-no-conversion.yaml
        ;;
esac

echo ""
echo "✅ Verifying CRD functionality restored..."
kubectl config use-context kind-target-cluster
kubectl get crd examples.conversion.example.com

echo "🔍 Testing API access..."
kubectl get examples.v1.conversion.example.com
kubectl get examples.v2.conversion.example.com
kubectl get examples

echo "📋 Testing resource creation..."
kubectl apply -f manifests/test-resources.yaml

echo ""
echo "🔄 Switching to Argo CD cluster..."
kubectl config use-context kind-argocd-cluster

echo "♻️  Triggering Argo CD cache refresh and application resync..."

# Invalidate cluster cache to ensure Argo CD sees the fixed state
TARGET_SERVER_RAW=$(kubectl config view --context=kind-target-cluster -o jsonpath='{.clusters[?(@.name=="kind-target-cluster")].cluster.server}')
TARGET_CONTAINER_IP=$(docker inspect target-cluster-control-plane --format='{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}')
TARGET_SERVER="https://${TARGET_CONTAINER_IP}:6443"
DOUBLE_ENCODED_SERVER=$(echo "$TARGET_SERVER" | sed 's/:/%253A/g' | sed 's/\//%252F/g')

# Invalidate cluster cache to ensure Argo CD sees the recovery
echo "🔄 Invalidating cluster cache to ensure Argo CD sees the recovery..."

# Check if port-forward is running by testing connectivity
if curl -k -s --connect-timeout 3 "http://localhost:8080/api/version" > /dev/null 2>&1; then
  echo "✅ Argo CD API is accessible at localhost:8080"

  # Get the admin password and authenticate
  ADMIN_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

  # Create temporary file for login request
  cat > /tmp/argocd-login.json << EOF
{
  "username": "admin",
  "password": "$ADMIN_PASSWORD"
}
EOF

  LOGIN_RESPONSE=$(curl -k -s -X POST \
    "http://localhost:8080/api/v1/session" \
    -H "Content-Type: application/json" \
    -d @/tmp/argocd-login.json 2>/dev/null || echo '{"error":"LOGIN_FAILED"}')

  # Clean up login file
  rm -f /tmp/argocd-login.json

  if echo "$LOGIN_RESPONSE" | grep -q '"token"'; then
    TOKEN=$(echo "$LOGIN_RESPONSE" | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')

    if [[ -n "$TOKEN" && "$TOKEN" != "null" ]]; then
      echo "✅ Authentication successful, invalidating cache..."

      # Create cache invalidation request file
      echo '{}' > /tmp/cache-invalidate.json

      curl -k -s -L -X POST \
        "http://localhost:8080/api/v1/clusters/$DOUBLE_ENCODED_SERVER/invalidate-cache" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $TOKEN" \
        -d @/tmp/cache-invalidate.json > /dev/null || echo "⚠️ Cache invalidation may have failed - applications will recover automatically"

      # Clean up cache file
      rm -f /tmp/cache-invalidate.json
    else
      echo "⚠️ Could not extract token - applications will recover automatically"
    fi
  else
    echo "⚠️ Authentication failed - applications will recover automatically"
  fi
else
  echo "⚠️ Argo CD API not accessible at localhost:8080"
  echo "💡 To enable API access, run in another terminal:"
  echo "   kubectl port-forward svc/argocd-server -n argocd 8080:443 &"
  echo "📋 Applications will recover automatically when they sync"
fi

echo "🔄 Triggering application resync..."
kubectl patch application external-cluster-app -n argocd --type='merge' -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' || true
kubectl patch application webhook-test-external -n argocd --type='merge' -p '{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}' || true

echo "⏳ Waiting for sync to complete..."
sleep 15

echo "✅ Checking application recovery..."
kubectl get applications -n argocd

echo ""
echo "🎉 CRD Evolution Fix Complete!"
echo "=============================="
echo ""
echo "✅ Verification steps:"
echo "1. Check Argo CD Dashboard: http://localhost:8080 (if port-forward is running)"
echo "2. Application status: kubectl get applications -n argocd"
echo "3. Target cluster resources:"
echo "   kubectl config use-context kind-target-cluster"
echo "   kubectl get examples"
echo "   kubectl get all -n webhook-system"
echo ""
echo "🎯 Applications should return to Synced/Healthy status"
echo "🔄 You can now run './scripts/break.sh' again to test the cycle"
echo ""
echo "🧠 What happened:"
if [ "$choice" = "1" ]; then
    echo "   • Direct kubectl deployment broke the chicken-and-egg deadlock"
    echo "   • Argo CD Application created for ongoing GitOps management"
    echo "   • Conversion webhook is now functional"
    echo "   • All CRD operations work normally"
elif [ "$choice" = "2" ]; then
    echo "   • CRD reverted to no-conversion strategy"
    echo "   • Both API versions work without webhooks"
    echo "   • Simpler but loses conversion capability"
else
    echo "   • Webhook service deployed directly using existing GitOps manifest"
    echo "   • Conversion webhook is now functional"
    echo "   • All CRD operations work normally"
fi
