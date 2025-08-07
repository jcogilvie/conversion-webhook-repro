# Kubernetes CRD Conversion Webhook Failure Reproduction

This reproduction case demonstrates the failure scenario where a CRD conversion webhook service becomes unavailable, causing `kubectl get crd` operations to fail, as described in [Argo CD issue #20828](https://github.com/argoproj/argo-cd/issues/20828).

## Prerequisites

- `kind` (Kubernetes in Docker) installed
- `kubectl` installed
- `helm` installed
- Docker running

## Quick Start

This project includes all necessary files to reproduce the webhook failure scenario.

### Step 1: Create a Kind Cluster

```bash
# Create a new kind cluster
kind create cluster --name webhook-test

# Verify cluster is running
kubectl cluster-info --context kind-webhook-test
```

### Step 2: Build and Load the Webhook Server

```bash
# Build the webhook server image
docker build -t webhook-conversion:latest .

# Load the image into the kind cluster
kind load docker-image webhook-conversion:latest --name webhook-test
```

### Step 3: Create the Webhook Service Namespace

```bash
kubectl create namespace webhook-system
```

### Step 4: Apply the CRD with Conversion Webhook

```bash
kubectl apply -f manifests/crd-with-webhook.yaml
```

### Step 5: Generate TLS Certificates for the Webhook

```bash
# Create a temporary directory for certs
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

# Create Kubernetes secret with the certificates
kubectl create secret tls webhook-certs \
  --cert=tls.crt \
  --key=tls.key \
  -n webhook-system

# Update the CRD with the correct CA bundle
CA_BUNDLE=$(cat ca.crt | base64 | tr -d '\n')
kubectl patch crd examples.conversion.example.com --type='merge' -p='{"spec":{"conversion":{"webhook":{"clientConfig":{"caBundle":"'$CA_BUNDLE'"}}}}}'

# Return to project directory
cd -
```

### Step 6: Deploy the Webhook Service

```bash
kubectl apply -f manifests/webhook-deployment.yaml
```

### Step 7: Verify Everything Works Initially

```bash
# Wait for the webhook pod to be ready
kubectl wait --for=condition=ready pod -l app=conversion-webhook -n webhook-system --timeout=60s

# Test that CRD retrieval works
kubectl get crd examples.conversion.example.com

# Create test resources
kubectl apply -f manifests/test-resources.yaml

# Verify the resources were created and conversion works
kubectl get examples test-example-v1 -o yaml
kubectl get examples test-example-v2 -o yaml

# Test conversion by getting both in different API versions
kubectl get examples test-example-v1 -o jsonpath='{.apiVersion}' && echo
kubectl get examples test-example-v2 -o jsonpath='{.apiVersion}' && echo
```

### Step 8: Install Argo CD to Observe the Failure

Now let's install Argo CD to demonstrate how this webhook failure affects real applications:

```bash
# Add the Argo CD Helm repository
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

# Create a namespace for Argo CD
kubectl create namespace argocd

# Install Argo CD via Helm
helm install argocd argo/argo-cd \
  --namespace argocd \
  --set server.service.type=ClusterIP \
  --set configs.params."server.insecure"=true

# Wait for Argo CD to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=argocd-server -n argocd --timeout=300s
```

### Step 9: Access Argo CD Dashboard

```bash
# Get the initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port forward to access the Argo CD dashboard
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Note: The dashboard will be available at http://localhost:8080
# Username: admin
# Password: (output from the command above)
```

Keep this port-forward running in the background. You can now access the Argo CD dashboard at http://localhost:8080

### Step 10: Create Argo CD Applications

Create Argo CD applications that will be affected by the webhook failure:

```bash
# Apply the Argo CD applications
kubectl apply -f manifests/argocd-applications.yaml
```

Wait for the applications to appear in the Argo CD dashboard, then proceed to the next step.

### Step 11: Simulate Webhook Service Failure

The most effective way to reproduce the webhook failure is to delete the service:

```bash
# Delete the webhook service entirely
kubectl delete service conversion-webhook-service -n webhook-system

# Verify the service is gone
kubectl get svc -n webhook-system
```

### Step 12: Force Argo CD Cache Refresh

After breaking the webhook service, we need to evict Argo CD's cache to see the full impact:

```bash
# Restart Argo CD components to force cache refresh
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd

# Wait for restarts to complete
kubectl rollout status deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd
```

Now you can observe how Argo CD reacts to the webhook failure:

**In the Argo CD Dashboard (http://localhost:8080):**
1. Navigate to the Applications view
2. Look for sync errors or health issues with applications
3. Check the application details for webhook-related errors

**Via CLI:**
```bash
# Check Argo CD application status
kubectl get applications -n argocd

# Get detailed status of our test application
kubectl describe application example-crd-app -n argocd

# Check Argo CD server logs for webhook errors
kubectl logs -l app.kubernetes.io/name=argocd-server -n argocd --tail=50

# Check repo server logs for webhook errors
kubectl logs -l app.kubernetes.io/name=argocd-repo-server -n argocd --tail=50
```

You should see Argo CD struggling with resource discovery or synchronization due to the webhook failures.

### Step 13: Reproduce the Direct Failures

Now trigger operations that invoke the conversion webhook. These will fail with the service deleted:

#### Failure Case 1: Create Time (Resource Creation)
```bash
# Try to apply the test resources - this will fail on the v1 resource
kubectl apply -f manifests/test-resources.yaml
```

This should produce an error like:
```
Error from server: error when retrieving current configuration of:
Resource: "conversion.example.com/v1, Resource=examples", GroupVersionKind: "conversion.example.com/v1, Kind=Example"
Name: "test-example-v1", Namespace: "default"
from server for: "manifests/test-resources.yaml": conversion webhook for conversion.example.com/v2, Kind=Example failed: Post "https://conversion-webhook-service.webhook-system.svc:443/convert?timeout=30s": service "conversion-webhook-service" not found
```

#### Failure Case 2: Read Time (Resource Access) - Replicates Argo CD Issue
```bash
# Clear kubectl cache and force API discovery
kubectl api-resources --api-group=conversion.example.com

# Try to access the v1 API version - this reliably triggers webhook calls
kubectl get examples.v1.conversion.example.com
```

This should produce an error like:
```
Error from server: conversion webhook for conversion.example.com/v2, Kind=Example failed: Post "https://conversion-webhook-service.webhook-system.svc:443/convert?timeout=30s": service "conversion-webhook-service" not found
```

#### Observe Argo CD Impact
After triggering these failures and restarting Argo CD components, check Argo CD again:
```bash
# Force Argo CD to refresh and see the impact
kubectl patch application example-crd-app -n argocd --type='merge' -p='{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Check for errors in Argo CD logs related to resource discovery
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=20 | grep -i "conversion\|webhook\|error"
```

### Expected Error Output

You should see errors similar to:

**For API version access:**
```
Error from server: conversion webhook for conversion.example.com/v2, Kind=Example failed: Post "https://conversion-webhook-service.webhook-system.svc:443/convert?timeout=30s": service "conversion-webhook-service" not found
```

**For resource creation/updates:**
```
Error from server: error when retrieving current configuration of:
Resource: "conversion.example.com/v1, Resource=examples", GroupVersionKind: "conversion.example.com/v1, Kind=Example"
Name: "test-example-v1", Namespace: "default"
from server for: "manifests/test-resources.yaml": conversion webhook for conversion.example.com/v2, Kind=Example failed: Post "https://conversion-webhook-service.webhook-system.svc:443/convert?timeout=30s": service "conversion-webhook-service" not found
```

**Key Points:**
- The webhook failure occurs when the API server tries to convert between v1 and v2 versions
- Operations involving v1 resources fail because v2 is the storage version, requiring conversion
- The error specifically mentions the missing service, demonstrating the exact failure mode
- This reproduces the same type of failure that affects Argo CD when conversion webhook services are unavailable
- **Argo CD Impact**: Resource discovery, synchronization, and health checks all fail when conversion webhooks are unavailable

### Step 14: Restore Service and Observe Recovery

To restore functionality and see Argo CD recover:

```bash
# Recreate the webhook service
kubectl apply -f manifests/webhook-deployment.yaml

# Wait for the pod to be ready (if deployment still exists)
kubectl wait --for=condition=ready pod -l app=conversion-webhook -n webhook-system --timeout=60s

# Verify operations work again
kubectl get examples.v1.conversion.example.com
kubectl get examples

# Restart Argo CD components again to clear error states
kubectl rollout restart deployment/argocd-server -n argocd
kubectl rollout restart deployment/argocd-repo-server -n argocd

# Wait for restarts to complete
kubectl rollout status deployment/argocd-server -n argocd
kubectl rollout status deployment/argocd-repo-server -n argocd

# Trigger Argo CD to resync and observe recovery
kubectl patch application example-crd-app -n argocd --type='merge' -p='{"operation":{"initiatedBy":{"username":"admin"},"sync":{"revision":"HEAD"}}}'

# Check Argo CD application status recovery
kubectl get applications -n argocd
```

You should see Argo CD applications return to healthy status once the webhook service is restored and caches are cleared.

### Step 15: Cleanup

```bash
# Stop the port-forward (if running in background, find the PID and kill it)
pkill -f "kubectl port-forward.*argocd-server" || echo "Port-forward already stopped"

# Delete test resources and applications
kubectl delete examples --all
kubectl delete applications --all -n argocd
kubectl delete -f manifests/

# Uninstall Argo CD
helm uninstall argocd -n argocd
kubectl delete namespace argocd
kubectl delete namespace webhook-system

# Delete the kind cluster
kind delete cluster --name webhook-test

# Clean up temporary certificate files
rm -rf /tmp/webhook-certs
```

## Key Points Demonstrated

1. **CRD Retrieval Failure**: When the conversion webhook service is unavailable, `kubectl get crd` operations fail
2. **Resource Operations Blocked**: All operations involving the CRD (create, read, update, delete) are blocked
3. **Kubernetes API Dependency**: The Kubernetes API server cannot process requests for the CRD without a working conversion webhook
4. **Service Discovery**: The error shows that Kubernetes tries to reach the webhook service but cannot establish a connection
5. **Argo CD Integration**: Demonstrates how these webhook failures directly impact Argo CD's ability to:
    - Discover and manage custom resources
    - Perform application synchronization
    - Maintain resource health monitoring
    - Execute automated sync policies
6. **Cache Management**: Shows the importance of restarting Argo CD components to properly observe webhook failures and recoveries

This reproduction case demonstrates the exact scenario described in the Argo CD issue where CRD operations fail when conversion webhook services are unavailable.

## Project Structure

```
webhook-conversion/
├── cmd/
│   └── webhook/
│       └── main.go
├── pkg/
│   └── webhook/
│       ├── conversion.go
│       ├── handler.go
│       └── types.go
├── manifests/
│   ├── crd-with-webhook.yaml
│   ├── webhook-deployment.yaml
│   ├── test-resources.yaml
│   └── argocd-applications.yaml
├── argocd-managed/
│   └── resources.yaml
├── go.mod
├── go.sum
├── Dockerfile
└── README.md
```
