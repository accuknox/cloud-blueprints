terraform {
  required_version = ">= 1.4"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "GCP Project ID"
}
variable "service_account_id" {
  description = "Service Account ID"
  type        = string
  default     = "gcp-aiml-onboarding-sa"
}
variable "service_account_display_name" {
  description = "Display Name for the Service Account"
  type        = string
  default     = "GCP-AIML-Onboarding-SA"
}

provider "google" {
  project = var.project_id
}

resource "google_service_account" "service_account" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
}

# ---- Project IAM roles ----
# Predefined roles granted to the AccuKnox service account on the project.
locals {
  project_roles = [
    "roles/viewer",                   # Read-only access to project resources
    "roles/iam.securityReviewer",     # Read IAM policies across the project
    "roles/aiplatform.viewer",        # Vertex AI / Agent Platform asset discovery
    "roles/agentregistry.viewer",     # Agent Registry read access
    "roles/bigquery.dataViewer",      # BigQuery data scanning
    "roles/storage.bucketViewer",     # Cloud Storage bucket metadata
    "roles/storage.objectViewer",     # Cloud Storage object data
  ]
}

resource "google_project_iam_member" "project_roles" {
  for_each = toset(local.project_roles)
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.service_account.email}"
}

# ---- Custom IAM roles ----
# Custom roles for permissions not covered by the predefined roles above.
locals {
  custom_roles = {
    storage_get_iam_policy = {
      role_id     = "custom_storage_get_policy_role"
      title       = "Custom role for storage buckets getIamPolicy"
      description = "Allows reading bucket IAM policy"
      permissions = ["storage.buckets.getIamPolicy"]
    }
    vertex_ai_predict = {
      role_id     = "custom_vertex_ai_predict_role"
      title       = "Custom role for Vertex AI predict"
      description = "Allows aiplatform.endpoints.predict only"
      permissions = ["aiplatform.endpoints.predict"]
    }
  }
}

resource "google_project_iam_custom_role" "custom_roles" {
  for_each    = local.custom_roles
  project     = var.project_id
  role_id     = each.value.role_id
  title       = each.value.title
  description = each.value.description
  permissions = each.value.permissions
}

resource "google_project_iam_member" "custom_roles" {
  for_each = google_project_iam_custom_role.custom_roles
  project  = var.project_id
  role     = each.value.name
  member   = "serviceAccount:${google_service_account.service_account.email}"
}

# ---- Service account key ----
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
