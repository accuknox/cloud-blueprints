variable "project_id" {
  description = "Customer GCP project ID in which the service account is created."
  type        = string
  default     = "ghostlight-491516"
}

variable "service_account_id" {
  description = "Account ID (local part) of the service account to create."
  type        = string
  default     = "cspm-scanner"
}
