# AccuKnox Azure Onboarding

## Overview

This Terraform module automatically onboards Azure subscriptions to AccuKnox via Azure Lighthouse. It uses Azure Policy to automatically create Lighthouse delegations for all subscriptions under a management group, including **new subscriptions created in the future**.

### What This Module Does

1. **Creates a Custom Azure Policy** that enforces Lighthouse delegation on all subscriptions
2. **Assigns the Policy** to your management group(s) 
3. **Automatically Onboards** existing and future subscriptions without manual intervention

### Key Benefits

- **Automatic Onboarding**: New subscriptions are automatically onboarded when created
- **Management Group Scope**: Apply to entire organizational hierarchies
- **Flexible Modes**: Include or exclude specific management groups/subscriptions

---

## Prerequisites & Permissions

### Required Permissions

Before deploying, ensure you have the following permissions in your Azure tenant:

#### 1. Management Group Permissions
- **Role**: `Owner` or `Resource Policy Contributor` on the target management group
- **Required For**: Creating policy definitions and assignments at the management group level

#### 2. Subscription Permissions
- **Role**: `Owner` on the context subscription (where Lighthouse definition is created)
- **Required For**: Creating the shared Lighthouse definition resource

### Required Tools

- **Terraform** >= 1.4.0
- **Azure CLI** (for authentication and verification)
- **Azure Account** with appropriate permissions (see above)

---

## Step-by-Step Deployment Guide

### Step 1: Configure Variables

1. **Check your `terraform.tfvars`**

2. **Find your Management Group ID:**
   ```bash
   az account management-group list \
     --query "[].{Name:name, DisplayName:displayName}" \
     -o table
   ```

### Step 2: Authenticate to Azure

```bash
# Login to your Azure tenant
az login

# Verify you're in the correct tenant
az account show --query "{TenantId:tenantId, SubscriptionId:id, Name:name}"

# Set your subscription context (if needed)
az account set --subscription "YOUR_SUBSCRIPTION_ID"
```

### Step 3: Initialize Terraform

```bash
cd azure
terraform init
```

This downloads the required Terraform providers (azurerm, azapi).

### Step 4: Review the Plan

```bash
terraform plan
```

Review what will be created:
- Custom policy definition
- Policy assignment(s) to management group(s)
- Lighthouse definition
- Remediation tasks

### Step 5: Deploy

```bash
terraform apply
```

Type `yes` when prompted. This will:
1. Create the custom Azure Policy definition
2. Assign the policy to your management group(s)
3. Create the shared Lighthouse definition
4. Create remediation tasks to onboard existing subscriptions

### Step 6: Verify Deployment

**Check Policy Assignment:**
```bash
# List policy assignments on your management group
az policy assignment list \
  --scope "/providers/Microsoft.Management/managementGroups/YOUR_MG_ID" \
  --query "[?contains(displayName, 'Lighthouse')].{Name:name, DisplayName:displayName}" \
  -o table
```

**Check Lighthouse Definition:**
```bash
# List Lighthouse definitions (from context subscription)
az account set --subscription "YOUR_CONTEXT_SUBSCRIPTION_ID"
az managedservices definition list -o table
```

**Check in Azure Portal:**
- Navigate to: **Policy** → **Assignments** → Filter by your management group
- Navigate to: **Subscriptions** → [Context Subscription] → **Service providers**

---

## How New Subscriptions Are Automatically Onboarded

### The Automatic Onboarding Process

Once this module is deployed, **new subscriptions are automatically onboarded** without any manual steps. Here's how it works:

#### 1. Policy Evaluation (Automatic)
- Azure Policy continuously monitors subscriptions under the assigned management group
- When a new subscription is created or moved under the management group, the policy detects it
- Policy evaluation happens automatically every 15-30 minutes

#### 2. Compliance Check (Automatic)
- The policy checks if the subscription has a Lighthouse assignment
- If missing, the subscription is marked as "NonCompliant"

#### 3. Automatic Remediation (Automatic)
- The policy's `deployIfNotExists` effect triggers automatically
- A Lighthouse assignment is created for the subscription
- The subscription becomes "Compliant"

#### 4. Visibility in AccuKnox (Automatic)
- Once the assignment exists, the subscription appears in AccuKnox tenant
- AccuKnox can now access the subscription via Lighthouse delegation

### Requirements for Automatic Onboarding

For a new subscription to be automatically onboarded, it must meet these requirements:

#### Requirement 1: Management Group Placement

The subscription must be under the management group where the policy is assigned (or any nested child management group).

**How to Verify:**
```bash
# Check which management group a subscription belongs to
az account management-group subscription show \
  --name "YOUR_SUBSCRIPTION_ID" \
  --query "{MGId:id, MGName:name, DisplayName:displayName}" \
  -o table
```

**How to Move a Subscription:**
1. Azure Portal → **Management Groups**
2. Select the target management group
3. Click **Subscriptions** → **Add subscription**
4. Select your subscription and click **Save**

#### Requirement 2: Resource Provider Registration

New subscriptions need these resource providers registered:

- **Microsoft.PolicyInsights** - Required for Azure Policy evaluation
- **Microsoft.ManagedServices** - Required for Lighthouse delegation

**Why This Matters:**
- New subscriptions don't have all providers registered by default
- The policy cannot create Lighthouse assignments without these providers
- Registration takes 1-2 minutes per provider

**How to Register (Choose One Method):**

**Method 1: Azure Portal (Recommended)**
1. Go to Azure Portal → **Subscriptions** → [Your Subscription]
2. Click **Resource providers** in the left menu
3. Search for `Microsoft.PolicyInsights` → Click **Register**
4. Search for `Microsoft.ManagedServices` → Click **Register**
5. Wait for both to show status as **"Registered"**

**Method 2: Azure CLI**
```bash
# Set subscription context
az account set --subscription "YOUR_SUBSCRIPTION_ID"

# Register both providers
az provider register --namespace Microsoft.PolicyInsights
az provider register --namespace Microsoft.ManagedServices

# Verify registration (should show "Registered")
az provider show --namespace Microsoft.PolicyInsights --query "registrationState"
az provider show --namespace Microsoft.ManagedServices --query "registrationState"
```

#### Requirement 3: Policy Evaluation Time

After meeting the above requirements, allow **15-30 minutes** for:
- Policy to evaluate the subscription
- Policy to create the Lighthouse assignment
- Subscription to appear in AccuKnox tenant

### Timeline for New Subscription Onboarding

```
Time        | What Happens
------------|--------------------------------------------------
0 min       | Subscription created or moved to management group
0-2 min     | Register resource providers (if not already done)
5-15 min    | Azure Policy evaluates the subscription
15-30 min   | Policy creates Lighthouse assignment (if compliant)
30+ min     | Subscription visible in AccuKnox tenant
```

---

## How to Check if a Subscription is Being Onboarded

### Quick Check: Manual Checks

#### 1. Check Resource Providers
```bash
az provider list \
  --query "[?namespace=='Microsoft.PolicyInsights' || namespace=='Microsoft.ManagedServices'].{Namespace:namespace, Status:registrationState}" \
  -o table
```

**Expected:** Both should show `Registered`

#### 2. Check Policy Compliance
```bash
az policy state list \
  --resource "/subscriptions/YOUR_SUBSCRIPTION_ID" \
  --query "[?contains(policyDefinitionName, 'Lighthouse')].{Policy:policyDefinitionName, Status:complianceState}" \
  -o table
```

**Expected:**
- `Compliant` = Lighthouse assignment exists 
- `NonCompliant` = Still deploying (wait 15-30 minutes) ⏳

#### 3. Check Lighthouse Assignment
```bash
az account set --subscription "YOUR_SUBSCRIPTION_ID"
az managedservices assignment list -o table
```

**Expected:** Should show at least one assignment with your Lighthouse definition

#### 4. Check in Azure Portal

**Policy Compliance:**
- Navigate to: **Policy** → **Compliance**
- Filter by your subscription
- Look for: "Auto-assign AccuKnox Lighthouse to new subscriptions"
- Status should be **"Compliant"**

**Lighthouse Assignment:**
- Navigate to: **Subscriptions** → [Your Subscription] → **Service providers**
- Should show "AccuKnox CSPM Integration" delegation

---

## Configuration Options

### Onboarding Modes

#### Mode 1: Include Mode
**Strategy:** "Only onboard these specific things..."

```hcl
mode = "include"

# Include specific management groups
included_management_group_ids = ["mg-development", "mg-testing"]

# Exclude specific subscriptions from included MGs
excluded_subscription_ids = ["test-sub-id"]

# Include extra subscriptions outside the included MGs
include_extra_subscription_ids = ["standalone-sub-id"]
```

**How it works:**
- Policy is assigned to each specified management group
- Only subscriptions under those MGs are onboarded
- Exceptions can be specified

#### Mode 2: Exclude Mode
**Strategy:** "Onboard everything except..."

```hcl
mode = "exclude"

# Exclude entire management groups
excluded_management_groups = ["mg-production", "mg-sensitive"]

# Exclude specific subscriptions globally
excluded_subscription_ids = ["sub-id-1", "sub-id-2"]

# Include exceptions (subscriptions to include even if their MG is excluded)
include_exception_subscription_ids = ["special-prod-sub-id"]
```

**How it works:**
- Single policy assignment to root management group
- Excludes specified management groups and subscriptions
- Creates individual assignments for exception subscriptions

### Variable Reference

See `terraform.tfvars.example` for all available variables and their descriptions.

**Key Variables:**
- `management_group_id` - Management group where policy is assigned
- `managing_tenant_id` - AccuKnox tenant ID (provided by AccuKnox)
- `accuknox_verification_token` - Security token (provided by AccuKnox, DO NOT MODIFY)
- `context_subscription_id` - Any subscription ID for Lighthouse definition creation
- `mode` - "include" or "exclude"
- `authorizations` - List of AccuKnox principals with delegated access

---

## What Gets Created

### Resources Created by Terraform

1. **Custom Policy Definition** (`azurerm_policy_definition`)
   - Defines the rule: "Each subscription must have Lighthouse assignment"
   - Uses `deployIfNotExists` effect to automatically create assignments

2. **Policy Assignment(s)** (`azurerm_management_group_policy_assignment`)
   - Assigns the policy to your management group(s)
   - Creates a system-assigned managed identity for remediation

3. **Role Assignment(s)** (`azurerm_role_assignment`)
   - Grants Owner role to policy identity (required for remediation)

4. **Lighthouse Definition** (`azurerm_lighthouse_definition`)
   - Shared definition used by all subscriptions
   - Contains authorizations (who can access what)

5. **Remediation Task(s)** (`azurerm_management_group_policy_remediation`)
   - Triggers immediate evaluation of existing subscriptions
   - Creates Lighthouse assignments for non-compliant subscriptions

6. **Lighthouse Assignments** (for existing subscriptions)
   - Created by Terraform for subscriptions discovered at deployment time
   - Future subscriptions are handled automatically by the policy

---


### List Management Groups

1. All MG
   ```code
      az graph query -q "
      ResourceContainers
      | where type == 'microsoft.resources/subscriptions'
      | extend mgChain = properties.managementGroupAncestorsChain
      | project subscriptionId, mgChain
      "
   ```

2. Tenant-Id Filter
   ```code
      az graph query -q "
      ResourceContainers
      | where type == 'microsoft.resources/subscriptions'
      | where tenantId == '<<--Tenant-Id-->>'
      | extend mgChain = properties.managementGroupAncestorsChain
      | project subscriptionId, mgChain
      "
   ```

3. List All Subscription with Name
   ```code
      az graph query -q "
      ResourceContainers 
      | where type == 'microsoft.resources/subscriptions' 
      | project subscriptionId, name
      "
   ```

---
## Support & Troubleshooting
Contact - support@accuknox.com
