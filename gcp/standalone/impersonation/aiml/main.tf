# AccuKnox GCP onboarding — impersonation-based scanning

# What this Script Does
#   1. Creates a dedicated service account for AccuKnox scanning.
#   2. Grants it the read-only roles needed for CSPM scanning.
#   3. Creates a custom role with storage.buckets.getIamPolicy and grants it.
#   4. Allows the AccuKnox principal to impersonate the service account
#      (roles/iam.serviceAccountTokenCreator on the SA itself).
#
# Usage:
#   terraform init
#   terraform apply -var="project_id=<customer-project-id>"
#
# After apply, share the `service_account_email` output (the Principal ID)
# with AccuKnox.

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

# AccuKnox service account that impersonates the created service account.
locals {
  accuknox_principal_email = "gcp-impersonate@shaped-infusion-402417.iam.gserviceaccount.com"
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
# 2. Built-in project roles
# ---------------------------------------------------------------------------

locals {
  project_roles = [
    "roles/iam.serviceAccountTokenCreator", # most important — required for impersonation flows
    "roles/iam.securityReviewer",           # Security Reviewer
    "roles/viewer",                         # Viewer
  ]
}

resource "google_project_iam_member" "scanner_roles" {
  for_each = toset(local.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.accuknox_scanner.email}"
}

# ---------------------------------------------------------------------------
# 3. Custom role: storage.buckets.getIamPolicy
# ---------------------------------------------------------------------------

resource "google_project_iam_custom_role" "bucket_iam_viewer" {
  role_id     = "accuknoxBucketIamViewer"
  title       = "AccuKnox Bucket IAM Viewer"
  description = "Allows reading IAM policies on storage buckets for CSPM scanning."
  permissions = ["storage.buckets.getIamPolicy"]
}

resource "google_project_iam_member" "scanner_custom_role" {
  project = var.project_id
  role    = google_project_iam_custom_role.bucket_iam_viewer.id
  member  = "serviceAccount:${google_service_account.accuknox_scanner.email}"
}

# ---------------------------------------------------------------------------
# 4. Allow the AccuKnox principal to impersonate this service account
#    ("Principals with access" on the SA → Service Account Token Creator)
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
