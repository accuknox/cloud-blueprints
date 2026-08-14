variable "mode" {
  description = "Onboarding mode: 'all', 'include', or 'exclude'"
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "include", "exclude"], var.mode)
    error_message = "Mode must be one of: all, include, exclude"
  }
}

variable "organization_id" {
  description = "Numeric ID of the Google Cloud organization where access will be delegated."
  type        = string
}

variable "auditor_service_account_email" {
  description = "Email of the auditing service account that should receive viewer permissions."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.auditor_service_account_email))
    error_message = "auditor_service_account_email must be a valid service account email (example: service-account@project.iam.gserviceaccount.com)."
  }
}

variable "provider_project_id" {
  description = "Optional project ID to use for quota and billing when managing organization-level resources. Leave empty to rely on Application Default Credentials."
  type        = string
  default     = ""
}

variable "impersonate_service_account" {
  description = "Optional service account email to impersonate when applying this configuration."
  type        = string
  default     = ""
}

variable "billing_project_id" {
  description = "Optional billing project to charge for API operations when using organization-level endpoints."
  type        = string
  default     = ""
}

variable "quota_project_id" {
  description = "Project ID to use for quota and billing when accessing organization-level APIs (e.g., Cloud Asset Inventory)."
  type        = string
  default     = ""
}

# ==============================================================================
# Mode-Specific Variables
# ==============================================================================

# ALL Mode variables
variable "all_excluded_project_ids" {
  description = "ALL mode: Projects to exclude from onboarding."
  type        = list(string)
  default     = []
}

# INCLUDE Mode variables
variable "included_folder_ids" {
  description = "INCLUDE mode: Folders to include. All projects under these folders (including nested) will be onboarded."
  type        = list(string)
  default     = []
}

variable "included_project_ids" {
  description = "INCLUDE mode: Cherry-pick projects from folders NOT in included_folder_ids."
  type        = list(string)
  default     = []
}

variable "include_excluded_project_ids" {
  description = "INCLUDE mode: Projects to exclude from included folders."
  type        = list(string)
  default     = []
}

# EXCLUDE Mode variables
variable "excluded_folder_ids" {
  description = "EXCLUDE mode: Folders to exclude. All projects under these folders (including nested) will be skipped."
  type        = list(string)
  default     = []
}

variable "exclude_excluded_project_ids" {
  description = "EXCLUDE mode: Projects to exclude from non-excluded folders."
  type        = list(string)
  default     = []
}

variable "exception_project_ids" {
  description = "EXCLUDE mode: Force-include projects from excluded folders."
  type        = list(string)
  default     = []
}

# ==============================================================================
# Deprecated/Legacy Variables (kept for backward compatibility)
# ==============================================================================

variable "project_ids" {
  description = "DEPRECATED: Use mode-specific variables instead. Optional list of additional project IDs to audit beyond those auto-discovered in the organization."
  type        = list(string)
  default     = []
}

# ==============================================================================
# IAM Configuration Variables
# ==============================================================================

variable "project_roles" {
  description = "Project-level IAM roles to apply to each project."
  type        = list(string)
  default = [
    "roles/compute.networkViewer",
    "roles/storage.objectViewer",
  ]
}

variable "folder_bindings" {
  description = "Optional set of folder-level bindings to grant the auditing identity."
  type = list(object({
    folder_id = string
    roles     = list(string)
  }))
  default = []
}

variable "additional_organization_roles" {
  description = "Additional organization-level roles to delegate to the auditing identity beyond the recommended defaults."
  type        = list(string)
  default     = []
}
