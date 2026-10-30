# AccuKnox GCP onboarding — impersonation-based scanning
#
# What this configuration does:
#   1. Creates a dedicated, read-only service account for AccuKnox scanning.
#   2. Enables the Policy Analyzer API (service-account last-authentication
#      activity for the identity inventory).
#   3. Grants it the built-in read-only roles needed for CSPM scanning, plus
#      the Policy Analyzer and Logging viewer roles used for identity
#      inventory enrichment.
#   4. Creates a custom role with storage.buckets.getIamPolicy and grants it.
#   5. Allows the AccuKnox principal to impersonate the scanner SA
#      (roles/iam.serviceAccountTokenCreator on the SA itself — NOT project-wide).
#
# Usage:
#   terraform init
#   terraform apply -var="project_id=<customer-project-id>"
#
# After apply, share the `service_account_email` output (the Principal ID)
# with AccuKnox.
#
# Cross-org note: the AccuKnox principal lives in AccuKnox's org. If the
# customer org enforces domain-restricted sharing
# (constraints/iam.allowedPolicyMemberDomains), the impersonation binding in
# section 5 will be REJECTED at apply time until the customer allowlists
# AccuKnox's customer ID. Check this before onboarding.
#
# Required APIs:
#   - Customer project: cloudresourcemanager.googleapis.com, iam.googleapis.com,
#     logging.googleapis.com (expected to be enabled already).
#     policyanalyzer.googleapis.com is enabled by this configuration (section 2).
#   - AccuKnox (caller) side: iamcredentials.googleapis.com

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
  }
}

provider "google" {
  project = var.project_id
}

# AccuKnox service account that impersonates the scanner SA created below.
locals {
  accuknox_principal_email = "accuknox-standalone-scanner@accuknox-gcp.iam.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# 1. Service account
# ---------------------------------------------------------------------------

resource "google_service_account" "accuknox_scanner" {
  account_id   = var.service_account_id
  display_name = "AccuKnox CSPM Scanner (impersonation)"
  description  = "Read-only service account impersonated by AccuKnox for security scanning."
}

# ---------------------------------------------------------------------------
# 2. Policy Analyzer API
#    Backs the service-account last-authentication lookup granted in section 3.
#    disable_on_destroy is false so destroying this onboarding stack never
#    switches the API off for other users of the project.
# ---------------------------------------------------------------------------

resource "google_project_service" "policyanalyzer" {
  project            = var.project_id
  service            = "policyanalyzer.googleapis.com"
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# 3. Built-in project roles
# ---------------------------------------------------------------------------

locals {
  project_roles = [
    # Core CSPM / identity inventory: iam.serviceAccounts.list,
    # iam.roles.get/list, resourcemanager.projects.getIamPolicy.
    "roles/iam.securityReviewer", # read IAM policies across resources
    "roles/viewer",               # read-only view of project resources

    # Identity inventory enrichment. Both are best-effort: without them the
    # affected lifecycle fields are null but collection still succeeds.
    #
    # Policy Analyzer serviceAccountLastAuthentication -> service-account
    # last_used (policyanalyzer.serviceAccountLastAuthenticationActivities.query).
    "roles/policyanalyzer.activityAnalysisViewer",

    # Admin Activity audit logs (logging.logEntries.list) -> service-account
    # created_at / created_by and human users' last_used. Viewer already
    # includes this; kept explicit so the dependency survives if Viewer is
    # ever narrowed.
    "roles/logging.viewer",
  ]
}

resource "google_project_iam_member" "scanner_roles" {
  for_each = toset(local.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.accuknox_scanner.email}"
}

# ---------------------------------------------------------------------------
# 4. Custom role: storage.buckets.getIamPolicy
# ---------------------------------------------------------------------------

resource "google_project_iam_custom_role" "bucket_iam_viewer" {
  role_id     = "accuknoxBucketIamViewer"
  title       = "Bucket IAM Viewer"
  description = "Allows reading IAM policies on storage buckets for CSPM scanning."
  permissions = ["storage.buckets.getIamPolicy"]
}

resource "google_project_iam_member" "scanner_custom_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.bucket_iam_viewer.id
  member  = "serviceAccount:${google_service_account.accuknox_scanner.email}"
}

# ---------------------------------------------------------------------------
# 5. Allow the AccuKnox principal to impersonate this service account
#    ("Principals with access" on the SA → Service Account Token Creator).
#    Scoped to THIS SA only — additive binding, won't clobber other grants.
# ---------------------------------------------------------------------------

resource "google_service_account_iam_member" "accuknox_impersonation" {
  service_account_id = google_service_account.accuknox_scanner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.accuknox_principal_email}"
}

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

output "service_account_email" {
  description = "Principal ID to share with AccuKnox."
  value       = google_service_account.accuknox_scanner.email
}

output "custom_role_id" {
  description = "Fully-qualified ID of the custom bucket IAM viewer role."
  value       = google_project_iam_custom_role.bucket_iam_viewer.id
}
