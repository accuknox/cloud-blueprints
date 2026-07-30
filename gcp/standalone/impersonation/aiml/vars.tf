variable "project_id" {
  description = "Customer GCP project ID in which the service account is created."
  type        = string
  default     = ""
}

variable "service_account_id" {
  description = "Account ID (local part) of the service account to create."
  type        = string
  default     = ""
}
