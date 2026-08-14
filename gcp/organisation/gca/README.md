# Cross-Organization Audit Bootstrap

This Terraform configuration delegates read-only visibility of a customer's Google Cloud organization to an external auditing service account. It applies the minimum recommended IAM bindings for security assessments and allows optional folder or project scoped overrides.

## Current Deployment

This setup demonstrates a cross-organization audit configuration where a CNAPP vendor is granted read-only access to a customer's GCP organization.

### Vendor (CNAPP Provider)
- **Vendor Account**: aksanoble@gmail.com
- **Vendor Project**: ontology-339307
- **Auditor Service Account**: accuknox-auditor@ontology-339307.iam.gserviceaccount.com

### Customer (Organization Being Audited)
- **Customer Organization**: 5gran.net (ID: 955809990560)
- **Customer Admin**: akshay@accuknox.com (runs this terraform to grant vendor access)
- **Customer Project** (for billing/quota): shaped-infusion-402417
- **Projects Being Audited**:
  - shaped-infusion-402417 (My First Project)
  - All other projects in the 5gran.net organization (auto-discovered)

### How It Works
The customer admin (akshay@accuknox.com) runs this Terraform configuration to grant the vendor's service account (accuknox-auditor@ontology-339307.iam.gserviceaccount.com) read-only access to their entire organization for security monitoring and compliance purposes.

## What gets created

- Organization-level viewer bindings for security, IAM, logging, cloud asset inventory, and organization policy metadata.
- Optional folder-level bindings for scoped access where full-organization roles are not desired.
- Project-level bindings (default: `roles/compute.networkViewer`, `roles/storage.objectViewer`) for every project you list, plus any bespoke bindings you define.

## Requirements

- Terraform 1.4 or later.
- HashiCorp Google provider 5.x or later.
- Apply credentials must have `roles/orgpolicy.policyViewer` (read), `roles/orgpolicy.policyAdmin` (write) or equivalent to manage organization IAM.
- The auditing service account must already exist in the auditor's organization.

## Quick start

```bash
cd terraform
terraform init
terraform plan \
  -var="organization_id=1234567890" \
  -var="auditor_service_account_email=audit-bot@example-audit.iam.gserviceaccount.com" \
  -var='project_ids=["customer-prod","customer-nonprod"]'
terraform apply
```

## Optional configuration

- `additional_organization_roles`: Supply extra organization-level roles beyond the defaults when specific services require more visibility.
- `folder_bindings`: Delegate roles at folder granularity instead of (or in addition to) full-organization access. Each entry needs a numeric folder ID (for example `0123456789` or `folders/0123456789`).
- `additional_project_bindings`: Grant project-specific roles without changing the baseline role list that applies to every project.
- `project_roles`: Override the default set of per-project roles if fewer or additional permissions are required.

## Provider hints

The provider block supports optional variables for advanced workflows:

- `provider_project_id`: Set when managing organization resources requires a billing/quota project.
- `impersonate_service_account`: Populate when you rely on workload identity federation or need to impersonate a privileged automation account.
- `billing_project_id`: Specify if the Google provider should charge API usage to a dedicated project.

## Security guidance

- Review granted roles regularly and prune any that are no longer needed.
- Pair this configuration with centralized log analysis (e.g., BigQuery, SIEM, or Security Command Center) on the auditor side.
- Organization policies such as `constraints/iam.allowedPolicyMemberDomains` may block cross-organization members; ensure the auditor's domain is approved before applying.
