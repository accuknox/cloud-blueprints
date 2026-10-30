variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "GCP Project ID"
}
variable "service_account_id" {
  description = "Service Account ID"
  type        = string
  default     = "gcp-onboarding-sa"
}
variable "service_account_display_name" {
  description = "Display Name for the Service Account"
  type        = string
  default     = "GCP-Onboarding-SA"
}

provider "google" {
  project = var.project_id
}

resource "google_project_service" "policyanalyzer" {
  project            = var.project_id
  service            = "policyanalyzer.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_iam_custom_role" "custom_role" {
  project     = var.project_id
  role_id     = "custom_storage_get_iam_policy_role"
  title       = "Custom role for storage buckets getIamPolicy"
  description = "Custom role to allow getting IAM policy for storage buckets"
  permissions = ["storage.buckets.getIamPolicy"]
}

resource "google_service_account" "service_account" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
}

resource "google_project_iam_member" "viewer_role" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "security_reviewer" {
  project = var.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "custom_role_assignment" {
  project = var.project_id
  role    = google_project_iam_custom_role.custom_role.name
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "policy_analyzer_viewer" {
  project = var.project_id
  role    = "roles/policyanalyzer.activityAnalysisViewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "logging_viewer" {
  project = var.project_id
  role    = "roles/logging.viewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_service_account_key" "sa_key" {
  service_account_id = google_service_account.service_account.name
}

resource "google_secret_manager_secret" "sa_key_secret" {
  secret_id = "accuknox-sa-key"
  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "sa_key_version" {
  secret      = google_secret_manager_secret.sa_key_secret.id
  secret_data = base64decode(google_service_account_key.sa_key.private_key)
}

output "service_account_email" {
  value = google_service_account.service_account.email
}

output "secret_name" {
  value       = google_secret_manager_secret.sa_key_secret.name
  description = "Retrieve key via: gcloud secrets versions access latest --secret=accuknox-sa-key"
}