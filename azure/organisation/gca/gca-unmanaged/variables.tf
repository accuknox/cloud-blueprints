
variable "managing_tenant_id" {
  description = "AccuKnox tenant ID"
  type        = string
  default     = "3d64034d-3c3e-4959-b019-f15558be8a4e"
}

variable "accuknox_verification_token" {
  description = "Unique verification token provided by AccuKnox (DO NOT MODIFY)."
  type        = string
  default     = "AK-CNAPP-483217"

  validation {
    condition     = can(regex("^AK-CNAPP-", var.accuknox_verification_token))
    error_message = "accuknox_verification_token must start with 'AK-CNAPP-'."
  }
}

variable "authorizations" {
  description = "AccuKnox principals"
  type = list(object({
    principal_id                  = string
    principal_display_name        = string
    role_definition_id            = string
    delegated_role_definition_ids = optional(list(string))
  }))
  default = [
    {
      principal_id           = "47e2ce34-c78d-4aaf-8f5f-300ec63c907f" # AccuKnox app registration
      principal_display_name = "AccuKnox CSPM Reader"
      role_definition_id     = "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader
    },
    {
      principal_id           = "cc2d4923-7605-4505-82e2-5235216d03fc"
      principal_display_name = "AccuKnox Scanner"
      role_definition_id     = "acdd72a7-3385-48ef-bd42-f606fba81ae7" # Reader
    }
  ]
}

variable "offer_name" {
  description = "Lighthouse offer name (shown under Subscriptions > Service providers)."
  type        = string
  default     = "AccuKnox Delegation for CSPM Scanning"
}

variable "offer_description" {
  description = "Lighthouse offer description."
  type        = string
  default     = "Delegated read-only access via Lighthouse"
}

variable "context_subscription_id" {
  description = "Subscription ID (GUID) in which the shared Lighthouse definition is created. Any subscription of the tenant works; it is also used as the Terraform provider context."
  type        = string
  default     = "7bf3366c-f7be-4e3e-aa98-b40f5977362d"

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(var.context_subscription_id)))
    error_message = "context_subscription_id must be set to a subscription ID (GUID)."
  }
}

variable "management_group_id" {
  description = "Root management group ID (name, e.g. \"my-root-grp\", or the tenant ID for the Tenant Root Group). Required for mode = \"all\" and mode = \"exclude\"; ignored for mode = \"include\"."
  type        = string
  default     = ""

  validation {
    condition     = trimspace(var.management_group_id) == "" || can(regex("(?i)^(/providers/microsoft\\.management/managementgroups/)?[a-z0-9._()-]+$", trimspace(var.management_group_id)))
    error_message = "management_group_id must be a management group name (letters, digits, '-', '_', '.', '(', ')')."
  }
}

# Onboarding mode - see "SUBSCRIPTION SELECTION" at the top of this file.
variable "mode" {
  description = "Subscription selection mode: \"all\" (everything under management_group_id), \"include\" (only included_management_group_ids + include_extra_subscription_ids) or \"exclude\" (everything under management_group_id except excluded_management_groups, plus include_exception_subscription_ids)."
  type        = string
  default     = ""

  validation {
    condition     = contains(["all", "include", "exclude"], var.mode)
    error_message = "mode must be one of \"all\", \"include\" or \"exclude\"."
  }
}

# --- Global exclusions (applied in every mode, always win) ---------------------------
variable "excluded_subscription_ids" {
  description = "Subscription IDs that must never be onboarded. Applied in every mode after all other rules, so a subscription listed here is skipped even if it is under an included management group or listed in include_extra_subscription_ids / include_exception_subscription_ids. Also excluded from the auto-onboarding policy."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.excluded_subscription_ids : trimspace(s) == "" || can(regex("(?i)^(/subscriptions/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(s)))])
    error_message = "excluded_subscription_ids entries must be subscription IDs (GUIDs)."
  }
}

# --- Include mode (mode = "include") -------------------------------------------------
variable "included_management_group_ids" {
  description = "INCLUDE mode: management groups to onboard. Every subscription under them (recursively) is onboarded and the auto-onboarding policy is assigned to each of them."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for m in var.included_management_group_ids : trimspace(m) == "" || can(regex("(?i)^(/providers/microsoft\\.management/managementgroups/)?[a-z0-9._()-]+$", trimspace(m)))])
    error_message = "included_management_group_ids entries must be management group names."
  }
}

variable "include_extra_subscription_ids" {
  description = "INCLUDE mode: extra individual subscriptions to onboard that are NOT under included_management_group_ids."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.include_extra_subscription_ids : trimspace(s) == "" || can(regex("(?i)^(/subscriptions/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(s)))])
    error_message = "include_extra_subscription_ids entries must be subscription IDs (GUIDs)."
  }
}

# --- Exclude mode (mode = "exclude") -------------------------------------------------
variable "excluded_management_groups" {
  description = "EXCLUDE mode: management groups (descendants of management_group_id) whose subscriptions are NOT onboarded (recursively). They are also excluded from the auto-onboarding policy."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for m in var.excluded_management_groups : trimspace(m) == "" || can(regex("(?i)^(/providers/microsoft\\.management/managementgroups/)?[a-z0-9._()-]+$", trimspace(m)))])
    error_message = "excluded_management_groups entries must be management group names."
  }
}

variable "include_exception_subscription_ids" {
  description = "EXCLUDE mode: subscriptions to onboard anyway even though they sit under an excluded management group."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for s in var.include_exception_subscription_ids : trimspace(s) == "" || can(regex("(?i)^(/subscriptions/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(s)))])
    error_message = "include_exception_subscription_ids entries must be subscription IDs (GUIDs)."
  }
}

variable "enable_auto_policy" {
  description = "Create the deployIfNotExists policy (definition, assignment, Owner role for its identity, remediation task) that delegates subscriptions created or moved under the management group(s) in the future. Set to false to onboard only the subscriptions that exist today."
  type        = bool
  default     = true
}

variable "register_resource_providers" {
  description = "Check Microsoft.ManagedServices and Microsoft.PolicyInsights in the context subscription and every onboarded subscription (\"az provider show\" at plan time) and register only the ones that are not registered yet (\"az provider register --wait\" at apply time); already-registered providers are skipped. Set to false if the Azure CLI is not available."
  type        = bool
  default     = true
}

variable "skip_inactive_subscriptions" {
  description = "Skip subscriptions whose state is Disabled, Warned or Deleted (delegations cannot be created in them). Skipped subscriptions are listed in the skipped_inactive_subscriptions output."
  type        = bool
  default     = true
}

variable "policy_definition_name" {
  description = "Name of the custom policy definition."
  type        = string
  default     = "Enable-Azure-Lighthouse-AccuKnox"
}

variable "policy_assignment_name" {
  description = "Name of the policy assignment (1-24 characters, unique per management group)."
  type        = string
  default     = "lh-enf"

  validation {
    condition     = length(var.policy_assignment_name) >= 1 && length(var.policy_assignment_name) <= 24
    error_message = "policy_assignment_name must be 1-24 characters."
  }
}

variable "policy_assignment_location" {
  description = "Azure region for the policy assignment's managed identity."
  type        = string
  default     = "eastus"
}

variable "deployment_location" {
  description = "Azure region used for the subscription-level deployments the policy performs."
  type        = string
  default     = "eastus"
}