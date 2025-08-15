# Kubernetes CRD Conversion Webhook Failure Reproduction

This reproduction case demonstrates the cluster-wide failure scenario that occurs when CRDs evolve to include conversion
webhooks that become unavailable, causing all applications in a target cluster to show "Unknown" status in Argo CD, as
described in [Argo CD issue #20828](https://github.com/argoproj/argo-cd/issues/20828).

## Reproduction Approach

This reproduction simulates a **realistic CRD evolution scenario** that triggers **cluster-wide failure**:

1. **Initial State**: CRD exists with multiple API versions (v1 storage, v2 served) but **no conversion webhook**
2. **Resources Created**: Applications create resources in both API versions successfully
3. **CRD Evolution**: CRD is updated to add a conversion webhook pointing to a non-existent service
4. **Cluster-Wide Failure**: Argo CD cache invalidation discovers the broken webhook, causing **all applications** in
   the target cluster to fail

## 🧠 **Critical Mechanism: Why This Causes Cluster-Wide Failure**

The key insight is the **storage vs served version configuration**:

- **v1 is the storage version** - all resources are stored in etcd as v1
- **v2 is served** - the API server offers both v1 and v2 APIs
- **When any client accesses the CRD** (even v1 resources), Kubernetes may need to convert between versions
- **Argo CD's cluster cache** builds by discovering all API resources, triggering conversions
- **With the webhook broken**, every conversion attempt fails, breaking the entire cluster cache

### Why Previous Reproductions Failed

Earlier attempts typically used v2 as storage version, which meant:

- v1 API access worked without conversion (no webhook needed)
- Only v2-specific operations failed
- Argo CD could still build cluster cache and manage most resources

**Our approach**: v1 storage + v2 served + broken webhook = **mandatory conversion for all operations** = cluster-wide
failure.

This mirrors real-world scenarios where:

- CRDs evolve from simple multi-version to requiring conversion webhooks
- Webhook services become unavailable after CRD updates
- The failure cascades to affect all cluster resources, not just the specific CRD

## Prerequisites

- `kind` (Kubernetes in Docker) installed
- `kubectl` installed
- `helm` installed
- Docker running

## Quick Start

This project includes all necessary files to reproduce the webhook failure scenario.

### Step 1: Run the Setup Script

```bash
# This creates clusters, installs Argo CD, and sets up the initial CRD without conversion webhook
./scripts/setup.sh
```

**What the setup script does:**

1. **Creates two Kind clusters**: `argocd-cluster` (management) and `target-cluster` (target for applications)
2. **Installs Argo CD** in the management cluster with self-management enabled
3. **Creates initial CRD** with v1 (storage) and v2 (served) versions **without** conversion webhook
4. **Creates test resources** in both API versions to verify functionality
5. **Registers target cluster** with Argo CD using service account authentication
6. **Creates cross-cluster applications** that deploy resources to the target cluster
7. **Verifies initial sync** and waits for applications to be healthy

The script is **idempotent** and can be run multiple times safely.

### Step 2: Access Argo CD Dashboard

```bash
# Get the initial admin password
kubectl config use-context kind-argocd-cluster
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d && echo

# Port forward to access the Argo CD dashboard
kubectl port-forward svc/argocd-server -n argocd 8080:443 &

# Access the dashboard at https://localhost:8080
# Username: admin
# Password: (output from the command above)
```

**Verify Initial State**: In the Argo CD dashboard, you should see applications successfully synced to the target
cluster.

### Step 3: Simulate CRD Evolution with Broken Webhook

```bash
# This simulates the realistic scenario where a CRD evolves to add conversion webhooks
./scripts/break.sh
```

**What the break script does:**

1. **Verifies current state** - Shows that resources are accessible in both API versions
2. **Removes webhook service** (if exists) - Simulates service unavailability with proper finalizer handling
3. **Applies evolved CRD** - Updates the CRD to add conversion webhook pointing to non-existent service
4. **Tests direct failures** - Confirms API access fails on target cluster due to broken webhook
5. **Forces Argo CD cache refresh** - Uses API authentication to invalidate cluster cache (if port-forward is running)
6. **Parses cluster response** - Intelligently detects and confirms the webhook failure
7. **Shows application impact** - Displays how all target cluster applications are affected

**🧠 Key Mechanism**: With v1 as storage and v2 as served, **every CRD operation requires conversion**, so the broken
webhook affects **all cluster operations**.

**Script Features:**
- **Secure**: No credential leaks - passwords and tokens are never displayed
- **Smart**: Only waits for application deletion if it exists, respects finalizers
- **Intelligent**: Parses API responses to confirm webhook failure detection
- **Graceful**: Provides helpful guidance when port-forward isn't running

### Step 4: Observe the Cluster-Wide Failure

After running the break script, you should observe:

**Expected break script output:**
```
🔥 Simulating CRD Evolution with Broken Conversion Webhook
🎯 Confirmed: Argo CD detected the broken conversion webhook
   Error: conversion webhook service not found
```

**In the Argo CD Dashboard:**

- All applications targeting the cluster show "Unknown" health status
- Applications cannot sync or refresh
- Resource details show conversion webhook errors

**Via CLI:**

```bash
# Check application status - all should show issues
kubectl get applications -n argocd

# Check application controller logs for the target error
kubectl logs -l app.kubernetes.io/name=argocd-application-controller -n argocd --tail=50

# Test direct access in target cluster (should fail)
kubectl config use-context kind-target-cluster
kubectl get examples  # This should fail
```

### Expected Error Output

You should see the **cluster-wide failure pattern**:

**Target Error Pattern (the one we want to reproduce):**

```
Failed to load target state: failed to get cluster version for cluster "https://172.18.0.3:6443": 
failed to get cluster info for "https://172.18.0.3:6443": error synchronizing cache state : 
failed to sync cluster https://172.18.0.3:6443: failed to load initial state of resource 
Example.conversion.example.com: conversion webhook for conversion.example.com/v1, Kind=Example failed: 
Post "https://conversion-webhook-service.webhook-system.svc:443/convert?timeout=30s": 
service "conversion-webhook-service" not found
```

**Argo CD Application Impact:**

- All applications targeting the cluster show "Unknown" health status
- Sync operations fail with cache synchronization errors
- Resource discovery fails cluster-wide

**Direct API Access (in target cluster):**

```bash
kubectl get examples
# Error: conversion webhook for conversion.example.com/v1, Kind=Example failed: 
# Post "https://conversion-webhook-service.webhook-system.svc:443/convert?timeout=30s": 
# service "conversion-webhook-service" not found
```

### Step 5: Restore Functionality

```bash
# Run the fix script to restore functionality
./scripts/fix.sh
```

**What the fix script does:**

The fix script offers **three restoration options**:

1. **Deploy working webhook service via Argo CD (GitOps approach)**:
   - Builds and loads webhook server Docker image
   - Generates proper TLS certificates with correct SAN names
   - Deploys webhook service directly to break the deadlock
   - Creates Argo CD application for ongoing GitOps management
   - Intelligently parses cache response to confirm restoration

2. **Remove conversion webhook (revert to no-conversion state)**:
   - Applies the original CRD manifest without conversion webhook
   - Simplest approach but loses conversion capability

3. **Deploy webhook service directly in target cluster (non-GitOps)**:
   - Generates certificates and deploys webhook using existing manifests
   - Direct kubectl approach without Argo CD application

**Script Features:**
- **Interactive**: Prompts user to choose restoration method
- **Secure**: No credential leaks during authentication
- **Intelligent**: Parses cluster response to confirm fix success
- **Comprehensive**: Verifies CRD functionality and application recovery

**Expected fix script output:**
```
🎯 Confirmed: Cluster connection restored - webhook is working
✅ Applications should return to Synced/Healthy status
```

**🔄 Repeatable Testing**: You can now run `./scripts/break.sh` and `./scripts/fix.sh` repeatedly to test the
failure/recovery cycle without full environment reset.

### Step 6: Verify Recovery

After running the fix script:

```bash
# Check that applications return to healthy status
kubectl get applications -n argocd

# Verify target cluster resource access works
kubectl config use-context kind-target-cluster
kubectl get examples

# Check Argo CD dashboard - applications should be Synced/Healthy
```

### Step 7: Cleanup

```bash
# Run the cleanup script to remove all resources
./scripts/cleanup.sh
```

This will:

- Delete both Kind clusters (and all resources automatically)
- Clean up temporary certificate files
- Reset the environment for fresh testing

## Script Details

### setup.sh
- **Purpose**: Creates complete test environment with two clusters and Argo CD
- **Runtime**: ~5-8 minutes for initial setup
- **Idempotent**: Can be run multiple times safely
- **Prerequisites**: Kind, kubectl, helm, Docker

### break.sh
- **Purpose**: Simulates CRD evolution with broken conversion webhook
- **Runtime**: ~30-60 seconds
- **Key Feature**: Intelligent API response parsing to confirm webhook failure
- **Security**: No credential leaks in output
- **Requirements**: Port-forward to Argo CD for optimal experience (optional)

### fix.sh
- **Purpose**: Restores functionality via multiple approaches
- **Runtime**: ~2-5 minutes depending on chosen option
- **Interactive**: Prompts for restoration method selection
- **Key Feature**: Intelligent cluster state detection to confirm recovery
- **Options**: GitOps deployment, webhook removal, or direct deployment

### cleanup.sh
- **Purpose**: Complete environment teardown
- **Runtime**: ~30 seconds
- **Effect**: Removes all Kind clusters and temporary files

## Key Points Demonstrated

This reproduction demonstrates the **exact cluster-wide failure scenario** from Argo CD issue #20828:

1. **🎯 Realistic CRD Evolution**: Simulates how CRDs evolve from simple multi-version to requiring conversion webhooks
2. **🌊 Cluster-Wide Impact**: Unlike resource-specific failures, this affects **ALL applications** in the target cluster
3. **⚡ Cache Synchronization Failure**: The error occurs during Argo CD's cluster cache building process, not individual
   resource operations
4. **🎮 Application Controller Impact**: The failure originates from the gitops-engine in the application controller,
   causing the "Unknown" status
5. **🔄 GitOps Integration**: Shows both failure and recovery through Argo CD application management
6. **🧠 Storage/Served Version Mechanics**: Demonstrates why v1 storage + v2 served + broken webhook = mandatory
   conversion failure

### Critical Insight: Storage vs Served Versions

**Why v1 storage + v2 served triggers cluster-wide failure:**

- All resources stored as v1 in etcd
- API server serves both v1 and v2
- **Any operation** may require conversion between versions
- Argo CD's cluster discovery triggers conversions during cache building
- Broken webhook = **every conversion fails** = **entire cluster cache fails**

This is different from v2 storage + v1 served, where v1 operations work without conversion.

### Difference from Other Webhook Failures

**Resource-Specific Failure** (what most reproductions show):

```
Failed to load live state: conversion webhook failed...
```

- Only affects apps using the specific CRD
- Occurs during resource comparison
- Apps show sync errors but remain "Healthy"

**Cluster-Wide Cache Failure** (this reproduction):

```
Failed to load target state: failed to get cluster version... error synchronizing cache state
```

- Affects **ALL** applications in the target cluster
- Occurs during cluster discovery/cache building
- Apps show "Unknown" health status
- Originates from application controller, not server/repo-server

This reproduction successfully demonstrates the second, more severe failure mode that was reported in the GitHub issue.

## Project Structure

```
webhook-conversion/
├── cmd/
│   └── webhook/
│       └── main.go                        # Webhook server main entry point
├── pkg/
│   └── webhook/
│       ├── conversion.go                  # Conversion logic between v1/v2
│       ├── handler.go                     # HTTP request handlers
│       └── types.go                       # Go type definitions for CRD
├── manifests/
│   ├── crd-no-conversion.yaml            # Initial CRD without webhook
│   ├── crd-with-broken-webhook.yaml      # Evolved CRD with broken webhook
│   ├── webhook-deployment.yaml           # Webhook service deployment
│   ├── test-resources.yaml               # Sample resources in both versions
│   ├── argocd-applications.yaml          # Cross-cluster applications
│   ├── external-cluster-applications.yaml # External cluster app templates
│   ├── argocd.yaml                       # Argo CD self-management
│   ├── argocd-manager-token.yaml         # Service account token template
│   └── target-cluster-secret.yaml        # Cluster registration template
├── webhook-service-managed/
│   └── resources.yaml                    # GitOps-managed webhook service
├── argocd-managed/
│   └── resources.yaml                    # Resources managed by Argo CD
├── scripts/
│   ├── setup.sh                          # Complete environment setup
│   ├── break.sh                          # CRD evolution failure simulation
│   ├── fix.sh                            # Multiple restoration approaches  
│   └── cleanup.sh                        # Environment teardown
├── go.mod                                # Go module definition
├── go.sum                                # Go module checksums
├── Dockerfile                            # Webhook server container image
├── .gitignore                            # Git ignore patterns
├── LICENSE                               # Apache 2.0 license
└── README.md                             # This file
```

## Key Features

- **GitOps-Native**: Uses Argo CD applications to manage webhook services
- **Repeatable**: Break/fix cycle without environment reset
- **Realistic**: Simulates actual CRD evolution scenarios
- **Educational**: Clear explanation of storage vs served version mechanics
- **Secure**: No credential leaks in script output
- **Intelligent**: API response parsing for confirmation of states
- **Complete**: Includes all necessary components for reproduction
- **Robust**: Proper finalizer handling and certificate management
