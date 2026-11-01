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

locals {
  accuknox_principal_email = "accuknox-standalone-scanner@accuknox-gcp.iam.gserviceaccount.com"
}


resource "google_service_account" "accuknox_scanner" {
  account_id   = var.service_account_id
  display_name = "AccuKnox CSPM Scanner (impersonation)"
  description  = "Read-only service account impersonated by AccuKnox for security scanning."
}

resource "google_project_service" "policyanalyzer" {
  project            = var.project_id
  service            = "policyanalyzer.googleapis.com"
  disable_on_destroy = false
}

locals {
  project_roles = [
    "roles/iam.securityReviewer", # read IAM policies across resources
    "roles/viewer",               # read-only view of project resources
    "roles/policyanalyzer.activityAnalysisViewer",
    "roles/logging.viewer",
  ]
}

resource "google_project_iam_member" "scanner_roles" {
  for_each = toset(local.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.accuknox_scanner.email}"
}

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

resource "google_service_account_iam_member" "accuknox_impersonation" {
  service_account_id = google_service_account.accuknox_scanner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${local.accuknox_principal_email}"
}

output "service_account_email" {
  description = "Principal ID to share with AccuKnox."
  value       = google_service_account.accuknox_scanner.email
}

output "custom_role_id" {
  description = "Fully-qualified ID of the custom bucket IAM viewer role."
  value       = google_project_iam_custom_role.bucket_iam_viewer.id
}
