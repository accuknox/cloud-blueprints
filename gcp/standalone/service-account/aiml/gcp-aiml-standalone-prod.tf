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
  default     = "ak-cloudwerx" # set default or pass via -var
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

variable "enable_apis" {
  description = "false: only check that the required APIs (local.required_apis) are enabled. true: enable any disabled required APIs automatically"
  type        = bool
  default     = false
}

provider "google" {
  project = var.project_id
}


# ---- Required APIs ----
# APIs AccuKnox needs on the project for onboarding and AI/ML scanning.
locals {
  required_apis = [
    "compute.googleapis.com",              # Compute Engine API
    "iam.googleapis.com",                  # Identity and Access Management (IAM) API
    "cloudresourcemanager.googleapis.com", # Cloud Resource Manager API
    "cloudfunctions.googleapis.com",       # Cloud Functions API
    "cloudkms.googleapis.com",             # KMS API
    "container.googleapis.com",            # Kubernetes Engine API
    "sqladmin.googleapis.com",             # Cloud SQL Admin API
    "aiplatform.googleapis.com",           # Agent Platform API - AI/ML asset discovery
    "agentregistry.googleapis.com",        # Agent Registry API - AI agent
    "bigquery.googleapis.com",             # BigQuery API - BigQuery data scanning
  ]
}

# enable_apis = false: reads each API's state without enabling it.
# The Service Usage API (serviceusage.googleapis.com) must be enabled for this check to run.
data "google_project_service" "required" {
  for_each = var.enable_apis ? toset([]) : toset(local.required_apis)
  project  = var.project_id
  service  = each.value
}

# APIs stay enabled on destroy so other workloads in the project are not affected.
resource "google_project_service" "required" {
  for_each = var.enable_apis ? toset(local.required_apis) : toset([])
  project  = var.project_id
  service  = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}

locals {
  # A disabled API comes back with an empty or placeholder id, or an empty service
  disabled_apis = sort([
    for svc, s in data.google_project_service.required : svc
    if s.id == "-" || s.id == "" || try(s.service, "") == ""
  ])
}

# Raise any required API is not present.
resource "terraform_data" "required_api_check" {
  input = local.disabled_apis

  lifecycle {
    precondition {
      condition     = length(local.disabled_apis) == 0
      error_message = <<-EOT
        The following required APIs are disabled on project ${var.project_id}:
          - ${join("\n  - ", local.disabled_apis)}

        Please enable them and run Terraform again:
          gcloud services enable ${join(" ", local.disabled_apis)} --project=${var.project_id}

        Or let Terraform enable them:
          terraform apply -var="enable_apis=true"
      EOT
    }
  }
}

resource "google_service_account" "service_account" {
  account_id   = var.service_account_id
  display_name = var.service_account_display_name

  depends_on = [terraform_data.required_api_check, google_project_service.required]
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

  depends_on = [terraform_data.required_api_check, google_project_service.required]
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

resource "local_file" "sa_key_file" {
  content  = base64decode(google_service_account_key.sa_key.private_key)
  filename = "${path.module}/service_account_key.json"
}

output "service_account_email" {
  value = google_service_account.service_account.email
}
output "key_file_path" {
  value = local_file.sa_key_file.filename
}
