# Oracle Cloud Onboarding Modes

This module mirrors the Google Cloud onboarding pattern (`all`, `include`, `exclude`) and generates Oracle Cloud Infrastructure (OCI) identity policies for a chosen principal (group, dynamic group, or user). It discovers compartments, builds the requested allow-list/deny-list logic, and renders policy statements that can be applied at the tenancy or compartment level.

## Prerequisites

- Configure the OCI Terraform provider (region/credentials) before using this module.
- Provide the tenancy OCID and the target principal (typically an IAM group or dynamic group).
- The caller must have permission to list compartments and create policies in the target compartment.

### Critical: Region Subscription Requirement

**For cross-tenancy access to work, both the AccuKnox (source) tenancy and the customer (destination) tenancy MUST be subscribed to at least one common OCI region.**

This is a fundamental OCI platform requirement. If there is no regional overlap between the two tenancies, cross-tenancy API calls will fail with `NotAuthorizedOrNotFound` or `NotAuthenticated` errors, even when policies are correctly configured.

#### Checking Region Subscriptions

List subscribed regions in a tenancy:
```bash
# Check customer tenancy
oci iam region-subscription list --profile CUSTOMER_PROFILE

# Check AccuKnox tenancy
oci iam region-subscription list --profile ACCUKNOX_PROFILE
```

#### Subscribing to a New Region

If there is no common region, subscribe the customer tenancy to one of AccuKnox's regions (recommended: `us-ashburn-1`):

```bash
# Subscribe to us-ashburn-1 (region key: IAD)
oci iam region-subscription create \
  --region-key IAD \
  --tenancy-id <customer_tenancy_ocid> \
  --profile CUSTOMER_PROFILE
```

Common region keys:
- `IAD` - us-ashburn-1 (US East - Virginia)
- `PHX` - us-phoenix-1 (US West - Arizona)
- `LHR` - uk-london-1 (UK South - London)
- `FRA` - eu-frankfurt-1 (Germany Central - Frankfurt)
- `BOM` - ap-mumbai-1 (India West - Mumbai)
- `SYD` - ap-sydney-1 (Australia East - Sydney)

**Note**: Region subscriptions typically complete within 30-60 seconds. Status transitions from `IN_PROGRESS` to `READY`.

## Usage

```hcl
module "oci_onboarding" {
  source = "../oracle"

  tenancy_ocid    = var.tenancy_ocid
  principal_type  = "group"
  principal_name  = "AccuKnox-Scanners"
  policy_name     = "accuknox-tenant-auditor"

  mode = "include"

  included_compartment_ocids = [
    "ocid1.compartment.oc1..aaaaexampleparent" # includes all descendants
  ]

  included_leaf_compartment_ocids = [
    "ocid1.compartment.oc1..bbbexampleleaf"    # cherry-picked compartment
  ]

  include_excluded_compartment_ocids = [
    "ocid1.compartment.oc1..cccignoreme"       # skip even though parent included
  ]

  cross_tenancy_enabled   = true
  principal_tenancy_ocid  = "ocid1.tenancy.oc1..vendorTenancyOcId"
  principal_tenancy_alias = "accuknox_vendor"
}
```

## Modes

- `all`: Discover every active compartment (including the tenancy root) and generate policies for all of them. Use `all_excluded_compartment_ocids` to omit specific compartments.
- `include`: Start empty, then add
  - every compartment under `included_compartment_ocids` (recursively),
  - plus explicit `included_leaf_compartment_ocids`.
  Remove unwanted compartments with `include_excluded_compartment_ocids`.
- `exclude`: Start from all compartments, remove any subtree listed in `excluded_compartment_ocids`, and optionally remove additional compartments via `exclude_additional_compartment_ocids`. Re-introduce individual exceptions with `exception_compartment_ocids`.

Regardless of mode, `extra_compartment_ocids` appends additional compartments after the mode is evaluated.

## Cross-Tenancy Access (Define/Endorse/Admit)

Setting `cross_tenancy_enabled = true` switches the module to Oracle's cross-tenancy policy model:

1. **Define** – the module creates `define tenancy <remote-ocid> as <alias>` in the customer tenancy.
2. **Admit** – generated statements become `admit <principal_type> <principal_name> of tenancy <alias> to ...`, granting the remote principal the requested permissions.
3. **Endorse** – the module outputs `cross_tenancy_endorse_statements`. Share these with the remote (AccuKnox) tenancy so they can create the matching `endorse` policy.

Inputs required for cross tenancy:

- `principal_type` – must be `group` or `dynamic-group`; we recommend placing the scanner user inside a group.
- `principal_name` – the group name in the remote tenancy.
- `principal_tenancy_ocid` – OCID of the remote (AccuKnox) tenancy.
- `principal_tenancy_alias` – human-friendly alias used in the Define/Admit/Endorse statements (e.g., `accuknox_vendor`).

You can view the generated statements with:

- `generated_policy_statements` – includes the Define + Admit statements applied in your tenancy.
- `cross_tenancy_define_statements` – just the Define statements for clarity.
- `cross_tenancy_endorse_statements` – copy/paste into the remote tenancy's policy so they can endorse the group.

## Policy statements

The module builds statements of the form:

```
allow|admit <principal_type> <principal_name> [of tenancy <alias>] to <action> <resource> in (tenancy|compartment <name>) [where <clause>]
```

Use `policy_permissions` to control the `<action>/<resource>` pairs. For advanced cases, append literal strings using `additional_policy_statements`.

## Outputs

- `final_compartment_ocids` / `final_compartment_names`: show which compartments received policies.
- `generated_policy_statements`: exact statements applied to the policy resource (Define + Admit when cross tenancy is enabled).
- `cross_tenancy_define_statements`: convenience view for the Define statements.
- `cross_tenancy_endorse_statements`: hand these to the remote tenancy for their policy.
- `compartment_debug_map`: optional discovery map (enabled by `mode_debug = true`) for troubleshooting.

## Notes

- Policies are created in `policy_compartment_ocid` (defaults to the tenancy).
- OCI policies cannot express explicit deny rules; exclusions work by omitting compartments from the generated statements.
- If an input OCID cannot be resolved, Terraform fails with a helpful error message before creating the policy.

## Troubleshooting Cross-Tenancy Access

### 1. Region Subscription Mismatch

**Symptom**: API calls fail with `NotAuthorizedOrNotFound` or `NotAuthenticated` errors, even with correct policies.

**Cause**: No common subscribed region between AccuKnox and customer tenancies.

**Solution**: Subscribe customer tenancy to a common region (see [Region Subscription Requirement](#critical-region-subscription-requirement) above).

### 2. Group Name Identity Domain Mismatch

**Symptom**: Cross-tenancy access fails after policies are created.

**Cause**: The group name in the Endorse policy doesn't exactly match the Admit policy.

**Example of incorrect configuration**:
- Endorse policy: `Endorse group default/AccuKnox-Scanners to ...`
- Admit policy: `admit group AccuKnox-Scanners of tenancy ...`

**Solution**: Ensure group names match **exactly** in both policies. Do not include the identity domain prefix (`default/`) in cross-tenancy policy statements when using group OCIDs in the `define group` statement:

```hcl
# Correct - no domain prefix in group name
Endorse group AccuKnox-Scanners to read all-resources in any-tenancy
admit group AccuKnox-Scanners of tenancy accuknox_vendor to read all-resources in tenancy
```

### 3. Limited IAM Entity Access Cross-Tenancy

**What Works with Cross-Tenancy Access:**
- ✅ **Compartments** - Full hierarchy discovery and inspection
- ✅ **Policies** - Read policy statements and configurations
- ✅ **Tenancy metadata** - Home region, subscription details
- ✅ **All cloud resources** - Compute, networking, databases, storage, etc.

**What Does NOT Work (OCI Platform Limitation):**
- ❌ **Users** - Cannot list or inspect IAM users
- ❌ **Groups** - Cannot list or inspect IAM groups
- ❌ **Group memberships** - Cannot determine which users belong to which groups
- ❌ **API Keys** - Cannot view user API key details
- ❌ **Auth tokens** - Cannot access user authentication tokens

**Why This Limitation Exists:**

OCI documentation states: _"OCI IAM Resources do not support Cross Tenancy Access"_ for security reasons. This is an intentional platform design decision to prevent external principals from enumerating a tenancy's user base and permission structure.

**Solution: Hybrid Approach (Sysdig Pattern)**

For comprehensive IAM auditing, follow the pattern used by Sysdig and other Cloud Security Providers:

1. **Cross-Tenancy Scanner** (Primary) - Use for all cloud resource discovery:
   - Compartment hierarchy
   - Compute instances, VCNs, subnets, security groups
   - Databases, storage buckets, load balancers
   - Cloud policies and configurations
   - **This covers 95% of CSPM/CNAPP use cases**

2. **Optional Local User** (IAM Auditing Only) - Create only when customer requires user/group auditing:
   ```bash
   # Create a minimal IAM-read-only user in customer tenancy
   oci iam user create \
     --name "accuknox-iam-reader" \
     --description "AccuKnox IAM audit user (read-only)" \
     --profile CUSTOMER_PROFILE

   # Assign minimal IAM read permissions
   # Policy: "Allow user accuknox-iam-reader to inspect users in tenancy"
   # Policy: "Allow user accuknox-iam-reader to inspect groups in tenancy"
   ```

**Reference:** Sysdig's OCI onboarding explicitly creates a local user for IAM resource collection while using cross-tenancy policies for all other resources. See: [Sysdig OCI Integration Docs](https://docs.sysdig.com/en/sysdig-secure/connect-oracle-cloud/)

**Recommendation:** Start with cross-tenancy access only. The ability to discover compartments cross-tenancy means AccuKnox can map the customer's organizational structure and scan all cloud resources without requiring a local user. Add a local IAM-reader user only if the customer specifically requires user/group auditing capabilities.

### 4. Policy Must Be in Root Compartment

**Symptom**: Policies don't take effect even though they're created successfully.

**Cause**: Cross-tenancy policies (`DEFINE`, `ENDORSE`, `ADMIT`) only work when placed in the root compartment of the tenancy.

**Solution**: Always set `policy_compartment_ocid = ""` (empty string defaults to tenancy root) or explicitly use the tenancy OCID as the compartment ID.

### 5. Testing Cross-Tenancy Access

To verify cross-tenancy access is working:

```bash
# Test compartment discovery (required for hierarchy mapping)
oci iam compartment list \
  --compartment-id <customer_tenancy_ocid> \
  --profile SCANNER \
  --compartment-id-in-subtree true

# Test cloud resource access - MUST specify region for each query
oci network vcn list \
  --compartment-id <customer_tenancy_ocid> \
  --profile SCANNER \
  --region us-ashburn-1 \
  --all

oci compute instance list \
  --compartment-id <customer_tenancy_ocid> \
  --profile SCANNER \
  --region us-ashburn-1 \
  --all

# Test database access
oci db autonomous-database list \
  --compartment-id <customer_tenancy_ocid> \
  --profile SCANNER \
  --region us-ashburn-1 \
  --all
```

**Important: Region-Specific Scanning**

OCI resources are region-specific. The scanner must query each subscribed region separately to discover all resources:

```bash
# Example: Scan VCNs in us-ashburn-1 region across all compartments
for compartment_id in $(oci iam compartment list \
  --compartment-id <customer_tenancy_ocid> \
  --profile SCANNER \
  --compartment-id-in-subtree true \
  --all | jq -r '.data[].id'); do

  echo "Scanning compartment: $compartment_id"
  oci network vcn list \
    --compartment-id "$compartment_id" \
    --profile SCANNER \
    --region us-ashburn-1
done
```

Repeat for each region the customer tenancy is subscribed to (e.g., `us-phoenix-1`, `eu-frankfurt-1`, etc.).

**Expected result:** Empty list `{"data": []}` or list of resources (no authorization errors)

**Example: Building Compartment Hierarchy**

The cross-tenancy scanner can reconstruct the complete compartment hierarchy:

```bash
# Get all compartments recursively
oci iam compartment list \
  --compartment-id <customer_tenancy_ocid> \
  --profile SCANNER \
  --compartment-id-in-subtree true \
  --all > compartments.json

# Each compartment includes:
# - name: Compartment name
# - id: Compartment OCID
# - compartment-id: Parent compartment OCID
# - description: Compartment description
# - lifecycle-state: ACTIVE/INACTIVE status

# Use parent-child relationships (compartment-id field)
# to build the organizational tree structure
```

This compartment discovery capability means AccuKnox can properly scope security scans and organize findings by organizational structure without requiring a local user.
