variable "management_group_id" {
  description = "Root management group ID where the policy will be assigned"
  type        = string
}

variable "managing_tenant_id" {
  description = "AccuKnox tenant ID"
  type        = string
}

variable "offer_name" {
  description = "Lighthouse offer name"
  type        = string
  default     = "AccuKnox CSPM Integration"
}

variable "accuknox_verification_token" {
  description = "Unique verification token provided by AccuKnox (DO NOT MODIFY)"
  type        = string

  validation {
    condition     = can(regex("^AK-CNAPP-", var.accuknox_verification_token))
    error_message = "Verification token must start with 'AK-CNAPP-'"
  }
}

variable "offer_description" {
  description = "Lighthouse offer description"
  type        = string
  default     = "Delegated read-only access for cloud security posture management via AccuKnox"
}

variable "authorizations" {
  description = "List of authorizations for Lighthouse"
  type = list(object({
    principal_id                  = string
    principal_display_name        = string
    role_definition_id            = string
    delegated_role_definition_ids = optional(list(string))
  }))
}

variable "policy_definition_name" {
  description = "Custom policy definition name"
  type        = string
  default     = "Enable-Azure-Lighthouse-AccuKnox"
}

variable "policy_assignment_name" {
  description = "Policy assignment name"
  type        = string
  default     = "lh-enf"

  validation {
    condition     = length(var.policy_assignment_name) >= 1 && length(var.policy_assignment_name) <= 24
    error_message = "policy_assignment_name must be 1-24 characters"
  }
}

variable "policy_assignment_location" {
  description = "Azure region for policy assignment managed identity"
  type        = string
  default     = "eastus"
}

variable "deployment_location" {
  description = "Location for ARM template deployments"
  type        = string
  default     = "eastus"
}

variable "context_subscription_id" {
  description = "Subscription ID where the shared lighthouse definition will be created"
  type        = string

  validation {
    condition     = var.context_subscription_id != null && var.context_subscription_id != ""
    error_message = "context_subscription_id must be provided"
  }
}

variable "mode" {
  description = "Onboarding mode: 'include' or 'exclude'"
  type        = string
  default     = "exclude"

  validation {
    condition     = contains(["include", "exclude"], var.mode)
    error_message = "mode must be 'include' or 'exclude'"
  }
}

variable "included_management_group_ids" {
  description = "Management groups to include (include mode only)"
  type        = list(string)
  default     = []
}

variable "excluded_subscription_ids" {
  description = "Subscriptions to exclude globally"
  type        = list(string)
  default     = []
}

variable "include_extra_subscription_ids" {
  description = "Extra subscriptions to include outside of management groups (include mode only)"
  type        = list(string)
  default     = []
}

variable "excluded_management_groups" {
  description = "Management groups to exclude (exclude mode only)"
  type        = list(string)
  default     = []
}

variable "include_exception_subscription_ids" {
  description = "Subscriptions to include even if their management group is excluded (exclude mode only)"
  type        = list(string)
  default     = []
}