variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "shaped-infusion-402417"  # set default or pass via -var
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

# Step 1: Create Custom Role
resource "google_project_iam_custom_role" "custom_storage_iam_role" {
  project     = var.project_id
  role_id     = "custom_storage_get_policy_role"
  title       = "Custom role for storage buckets getIamPolicy"
  description = "Allows reading bucket IAM policy"
  permissions = ["storage.buckets.getIamPolicy"]
}

# Step 2: Create Service Account
resource "google_service_account" "service_account" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name
}

# Step 3: Assign Viewer role to the service account
resource "google_project_iam_member" "viewer_role" {
  project = var.project_id
  role    = "roles/viewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Step 4: Assign custom role to the service account
resource "google_project_iam_member" "security_reviewer" {
  project = var.project_id
  role    = "roles/iam.securityReviewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "vertex_ai_viewer" {
  project = var.project_id
  role    = "roles/aiplatform.viewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "storage_bucket_viewer" {
  project = var.project_id
  role    = "roles/storage.bucketViewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "storage_object_viewer" {
  project = var.project_id
  role    = "roles/storage.objectViewer"
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_custom_role" "predict_role" {
  project     = var.project_id
  role_id     = "custom_vertex_ai_predict_role"
  title       = "Custom role for Vertex AI predict"
  description = "Allows aiplatform.endpoints.predict only"
  permissions = ["aiplatform.endpoints.predict"]
}

resource "google_project_iam_member" "custom_storage_role_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.custom_storage_iam_role.name
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

resource "google_project_iam_member" "custom_predict_role_binding" {
  project = var.project_id
  role    = google_project_iam_custom_role.predict_role.name
  member  = "serviceAccount:${google_service_account.service_account.email}"
}

# Step 5: Generate JSON key for service account and store in Secret Manager
resource "google_service_account_key" "sa_key" {
  service_account_id = google_service_account.service_account.name
}

# Step 6: Save Key to Secret Manager
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
