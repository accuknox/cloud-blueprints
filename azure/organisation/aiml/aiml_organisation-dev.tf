terraform {
  required_version = ">= 1.7.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 4.26.0, < 5.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.9"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.47.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = trimspace(var.context_subscription_id)
  resource_provider_registrations = "none"
}


########################################################
# Variables
########################################################

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
  default     = ""

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

# --- AccuKnox application identity ---------------------------------------------------
# Shared by the Microsoft Graph, AI/ML and Power Platform grants below
variable "accuknox_app_client_id" {
  description = "Client (application) ID of the AccuKnox enterprise app / service principal in the customer tenant, used for Graph permission grants and the Power Platform application user."
  type        = string
  default     = "384d0c6d-8e35-489a-8833-346c5bbf2dbc"

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(var.accuknox_app_client_id)))
    error_message = "accuknox_app_client_id must be a client ID (GUID)."
  }
}

# --- Microsoft Graph permissions -----------------------------------------------------
# Entra ID app role assignments (application permissions, admin-consented). Lighthouse
# delegates Azure resources only, so directory-level reads have to be granted here.
variable "enable_graph_permissions" {
  description = "Grant the AccuKnox service principal Microsoft Graph application permissions. Requires Privileged Role Administrator or Global Administrator"
  type        = bool
  default     = false
}

variable "graph_app_role_ids" {
  description = "Microsoft Graph app role (application permission) IDs granted and consented to the AccuKnox service principal."
  type        = list(string)
  default = [
    "20e6f8e4-ffac-4cf7-82f7-70ddb7564318", # AuditLogsQuery-CRM.Read.All
  ]

  validation {
    condition     = alltrue([for r in var.graph_app_role_ids : can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(r)))])
    error_message = "graph_app_role_ids entries must be app role IDs (GUIDs)."
  }
}

# --- AI/ML scanning ------------------------------------------------------------------
# Direct AI/ML RBAC grants for the AccuKnox service principal.
variable "enable_aiml_access" {
  description = "Grant the AccuKnox service principal the AI/ML scanning roles (Storage Blob Data Reader, Cognitive Services Data Reader, Foundry Agent Consumer) directly on every onboarded subscription. Set to false to onboard General cloud only."
  type        = bool
  default     = true
}

variable "enable_ml_scanner_custom_role" {
  description = "Create the custom \"ML scanner\" role (listing actions that no built-in read-only role covers) and assign it to the AccuKnox service principal on every onboarded subscription. Requires rights to write role definitions. Ignored when enable_aiml_access = false."
  type        = bool
  default     = true
}

variable "ml_scanner_role_name" {
  description = "Name of the custom ML scanner role. Must be unique within the customer tenant."
  type        = string
  default     = "AccuKnox ML Scanner"
}

variable "role_definition_propagation_delay" {
  description = "How long to wait after creating the custom ML scanner role before assigning it, so Azure RBAC can replicate the definition. Increase it if the apply still fails with \"RoleAssignmentScopeNotAssignableToRoleDefinition\"."
  type        = string
  default     = "20s"

  validation {
    condition     = can(regex("^[0-9]+(s|m|h)$", var.role_definition_propagation_delay))
    error_message = "role_definition_propagation_delay must be a duration such as \"90s\", \"3m\" or \"1h\"."
  }
}

locals {
  aiml_builtin_role_definition_ids = [
    "2a2b9908-6ea1-4ae2-8e65-a410df84e7d1", # Storage Blob Data Reader
    "b59867f0-fa02-499b-be73-45a86b5b3e1c", # Cognitive Services Data Reader
    "eed3b665-ab3a-47b6-8f48-c9382fb1dad6", # Foundry Agent Consumer
  ]
}

# AI discovery
locals {
  discovery_permissions = {
    actions = [
      "Microsoft.Resources/subscriptions/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Resources/subscriptions/resourceGroups/resources/read",

      "Microsoft.MachineLearningServices/workspaces/read",
      "Microsoft.MachineLearningServices/workspaces/*/read",

      "Microsoft.CognitiveServices/accounts/read",
      "Microsoft.CognitiveServices/accounts/projects/read",
      "Microsoft.CognitiveServices/accounts/deployments/read",

      "Microsoft.Storage/storageAccounts/read",
    ]
    data_actions = []
  }
}

# Classic Foundry: hub-based projects (Azure Machine Learning workspaces), classic Agent Service
# and Azure OpenAI Assistants.
locals {
  classic_foundry_permissions = {
    actions = [
      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action",
      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/token/action",
      "Microsoft.MachineLearningServices/workspaces/serverlessEndpoints/listKeys/action",
      "Microsoft.MachineLearningServices/workspaces/agents/action",
    ]
    data_actions = [
      "Microsoft.CognitiveServices/accounts/AIServices/agents/write",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/write",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/messages/write",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/runs/write",
    ]
  }
}

# New Foundry: Foundry resources and projects.
locals {
  new_foundry_permissions = {
    actions = []
    data_actions = [
      "Microsoft.CognitiveServices/accounts/AIServices/applications/invoke/action",
      "Microsoft.CognitiveServices/accounts/MaaS/*/action",
      "Microsoft.CognitiveServices/accounts/AIServices/evaluations/write",
    ]
  }
}

# Azure OpenAI model inference, used by both classic and new Foundry.
locals {
  shared_model_permissions = {
    actions = []
    data_actions = [
      "Microsoft.CognitiveServices/accounts/OpenAI/deployments/*/action",
    ]
  }
}

# Built from every group in permission_groups; add or remove a group here and the role follows.
locals {
  permission_groups = {
    discovery       = local.discovery_permissions
    classic_foundry = local.classic_foundry_permissions
    new_foundry     = local.new_foundry_permissions
    shared_model    = local.shared_model_permissions
  }

  custom_role_permissions = {
    actions      = distinct(flatten([for group in local.permission_groups : group.actions]))
    data_actions = distinct(flatten([for group in local.permission_groups : group.data_actions]))
  }
}

# --- Power Platform (Dataverse) ------------------------------------------------------
# Power Platform sits outside the Azure Resource Manager hierarchy, so neither Lighthouse
# nor an Azure role assignment reaches it. Registration is performed through the BAP and
# Dataverse REST APIs using the operator's existing Azure CLI authentication.
variable "enable_powerplatform_registration" {
  description = "Register the AccuKnox application as an application user in selected Dataverse environments through the BAP/Dataverse REST APIs. Requires Power Platform/Dataverse administrator permissions. Set to false to skip."
  type        = bool
  default     = true
}

variable "powerplatform_environment_selection" {
  description = "'all' = every Dataverse environment the operator can access from the BAP API; 'specific' = only environments listed in only_environment_display_names."
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "specific"], var.powerplatform_environment_selection)
    error_message = "powerplatform_environment_selection must be 'all' or 'specific'."
  }
}

variable "only_environment_display_names" {
  description = "Environment display names to onboard when powerplatform_environment_selection = 'specific'. Ignored when selection = 'all'."
  type        = list(string)
  default     = []
}

variable "dataverse_security_role_name" {
  description = "Dataverse security role assigned to the AccuKnox application user."
  type        = string
  default     = "Service Reader"
}

variable "powerplatform_request_timeout_seconds" {
  description = "Maximum seconds per Power Platform authentication or HTTP request (requires GNU timeout, curl, and jq)."
  type        = number
  default     = 30

  validation {
    condition     = var.powerplatform_request_timeout_seconds >= 5 && var.powerplatform_request_timeout_seconds <= 300 && floor(var.powerplatform_request_timeout_seconds) == var.powerplatform_request_timeout_seconds
    error_message = "powerplatform_request_timeout_seconds must be an integer between 5 and 300."
  }
}

variable "powerplatform_discovery_timeout_seconds" {
  description = "Maximum seconds for the entire BAP environment discovery, including all pages."
  type        = number
  default     = 120

  validation {
    condition     = var.powerplatform_discovery_timeout_seconds >= 5 && var.powerplatform_discovery_timeout_seconds <= 600 && floor(var.powerplatform_discovery_timeout_seconds) == var.powerplatform_discovery_timeout_seconds
    error_message = "powerplatform_discovery_timeout_seconds must be an integer between 5 and 600."
  }
}

variable "powerplatform_skip_environment_ids" {
  description = "Environment IDs where registration is known to be unsupported. Creation is skipped, but existing users are still cleaned up on destroy."
  type        = set(string)
  default     = []
}

variable "powerplatform_api_version" {
  description = "BAP API version used for environment discovery."
  type        = string
  default     = "2021-04-01"
}


locals {
  context_subscription_id = lower(trimspace(var.context_subscription_id))

  root_management_group_id = trimspace(var.management_group_id) == "" ? "" : element(reverse(split("/", trimspace(var.management_group_id))), 0)

  included_management_group_ids = toset([
    for m in var.included_management_group_ids : element(reverse(split("/", trimspace(m))), 0) if trimspace(m) != ""
  ])

  excluded_management_group_ids = toset([
    for m in var.excluded_management_groups : element(reverse(split("/", trimspace(m))), 0) if trimspace(m) != ""
  ])

  excluded_subscription_ids = toset([
    for s in var.excluded_subscription_ids : lower(element(reverse(split("/", trimspace(s))), 0)) if trimspace(s) != ""
  ])

  include_extra_subscription_ids = toset([
    for s in var.include_extra_subscription_ids : lower(element(reverse(split("/", trimspace(s))), 0)) if trimspace(s) != ""
  ])

  include_exception_subscription_ids = toset([
    for s in var.include_exception_subscription_ids : lower(element(reverse(split("/", trimspace(s))), 0)) if trimspace(s) != ""
  ])

  uses_root_management_group = contains(["all", "exclude"], var.mode)
}


resource "terraform_data" "input_validation" {
  lifecycle {
    precondition {
      condition     = var.mode != "include" || length(local.included_management_group_ids) + length(local.include_extra_subscription_ids) > 0
      error_message = "mode = \"include\" requires at least one entry in included_management_group_ids or include_extra_subscription_ids."
    }

    precondition {
      condition     = var.mode == "include" || (length(local.included_management_group_ids) == 0 && length(local.include_extra_subscription_ids) == 0)
      error_message = "included_management_group_ids and include_extra_subscription_ids are only used when mode = \"include\" - clear them or change mode."
    }

    precondition {
      condition     = var.mode == "exclude" || (length(local.excluded_management_group_ids) == 0 && length(local.include_exception_subscription_ids) == 0)
      error_message = "excluded_management_groups and include_exception_subscription_ids are only used when mode = \"exclude\" - clear them or change mode."
    }

    precondition {
      condition     = !contains([for m in local.excluded_management_group_ids : lower(m)], lower(local.root_management_group_id))
      error_message = "management_group_id itself cannot be listed in excluded_management_groups."
    }
  }
}


data "azurerm_management_group" "root" {
  count = local.uses_root_management_group ? 1 : 0
  name  = local.root_management_group_id

  lifecycle {
    precondition {
      condition     = local.root_management_group_id != ""
      error_message = "management_group_id must be set when mode = \"all\" or mode = \"exclude\"."
    }
  }
}

data "azurerm_management_group" "included" {
  for_each = var.mode == "include" ? local.included_management_group_ids : toset([])
  name     = each.value
}

data "azurerm_management_group" "excluded" {
  for_each = var.mode == "exclude" ? local.excluded_management_group_ids : toset([])
  name     = each.value

  lifecycle {
    precondition {
      condition     = contains(local.root_descendant_management_group_ids, lower(each.value))
      error_message = "excluded_management_groups entry \"${each.value}\" is not a descendant of management_group_id \"${local.root_management_group_id}\"."
    }
  }
}

# Subscription states (Enabled / Warned / PastDue / Disabled / Deleted) of every
# subscription visible to the deploying identity.
data "azurerm_subscriptions" "visible" {
  count = var.skip_inactive_subscriptions ? 1 : 0
}


locals {
  root_descendant_management_group_ids = [
    for id in try(data.azurerm_management_group.root[0].all_management_group_ids, []) :
    lower(element(reverse(split("/", id)), 0))
  ]

  root_subscription_ids = toset([
    for s in try(data.azurerm_management_group.root[0].all_subscription_ids, []) : lower(s)
  ])

  included_mg_subscription_ids = toset(flatten([
    for mg in data.azurerm_management_group.included : try([for s in mg.all_subscription_ids : lower(s)], [])
  ]))

  excluded_mg_subscription_ids = toset(flatten([
    for mg in data.azurerm_management_group.excluded : try([for s in mg.all_subscription_ids : lower(s)], [])
  ]))

  # Mode rules
  candidate_subscription_ids = (
    var.mode == "all" ? local.root_subscription_ids :
    var.mode == "include" ? setunion(local.included_mg_subscription_ids, local.include_extra_subscription_ids) :
    setunion(setsubtract(local.root_subscription_ids, local.excluded_mg_subscription_ids), local.include_exception_subscription_ids)
  )

  # Global exclusions always win
  selected_subscription_ids = setsubtract(local.candidate_subscription_ids, local.excluded_subscription_ids)

  # Drop subscriptions in which a delegation cannot be created
  inactive_subscription_states = ["Disabled", "Warned", "Deleted"]

  subscription_states = {
    for s in try(data.azurerm_subscriptions.visible[0].subscriptions, []) : lower(s.subscription_id) => s.state
  }

  skipped_inactive_subscriptions = {
    for id in local.selected_subscription_ids : id => local.subscription_states[id]
    if contains(local.inactive_subscription_states, lookup(local.subscription_states, id, "Enabled"))
  }

  # Final list of subscriptions that receive a Lighthouse assignment
  target_subscription_ids = setsubtract(local.selected_subscription_ids, keys(local.skipped_inactive_subscriptions))

  # Management groups that receive the auto-onboarding policy
  policy_scope_management_group_ids = !var.enable_auto_policy ? toset([]) : (
    var.mode == "include" ? local.included_management_group_ids : toset([local.root_management_group_id])
  )

  # Scopes the policy must never touch: excluded management groups (exclude mode) and
  # globally excluded subscriptions (every mode).
  policy_not_scopes = concat(
    var.mode == "exclude" ? [for m in sort(tolist(local.excluded_management_group_ids)) : "/providers/Microsoft.Management/managementGroups/${m}"] : [],
    [for s in sort(tolist(local.excluded_subscription_ids)) : "/subscriptions/${s}"],
  )

  owner_role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"

  resource_provider_namespaces = ["Microsoft.ManagedServices", "Microsoft.PolicyInsights"]

  resource_provider_subscription_ids = var.register_resource_providers ? setunion(local.target_subscription_ids, [local.context_subscription_id]) : toset([])
}

locals {
  resource_provider_checks = {
    for pair in setproduct(local.resource_provider_subscription_ids, local.resource_provider_namespaces) :
    "${pair[0]}/${pair[1]}" => {
      subscription_id = pair[0]
      namespace       = pair[1]
    }
  }
}

data "external" "resource_provider_state" {
  for_each = local.resource_provider_checks

  program = [
    "az", "provider", "show",
    "--namespace", each.value.namespace,
    "--subscription", each.value.subscription_id,
    "--query", "{registrationState: registrationState}",
    "--output", "json",
    "--only-show-errors",
  ]
}

locals {
  resource_provider_actions = {
    for key, check in local.resource_provider_checks : key => merge(check, {
      registration_state = try(data.external.resource_provider_state[key].result.registrationState, "Unknown")
      action             = lower(try(data.external.resource_provider_state[key].result.registrationState, "")) == "registered" ? "skip" : "register"
    })
  }
}

resource "terraform_data" "resource_provider_registration" {
  for_each = local.resource_provider_actions

  # The decision is recorded when a pair is first seen (visible in the plan as
  # input.action = "register" | "skip"); later state changes do not create diffs.
  input = each.value

  lifecycle {
    ignore_changes = [input]
  }

  provisioner "local-exec" {
    command = (
      self.input.action == "register"
      ? "az provider register --namespace ${self.input.namespace} --subscription \"${self.input.subscription_id}\" --wait"
      : "echo ${self.input.namespace} is already registered in subscription ${self.input.subscription_id} - skipping"
    )
  }
}


resource "azurerm_lighthouse_definition" "this" {
  name               = "${var.offer_name} - ${var.accuknox_verification_token}"
  description        = var.offer_description
  managing_tenant_id = var.managing_tenant_id
  scope              = "/subscriptions/${local.context_subscription_id}"

  dynamic "authorization" {
    for_each = var.authorizations
    content {
      principal_id                  = authorization.value.principal_id
      principal_display_name        = authorization.value.principal_display_name
      role_definition_id            = authorization.value.role_definition_id
      delegated_role_definition_ids = authorization.value.delegated_role_definition_ids
    }
  }

  depends_on = [terraform_data.resource_provider_registration]
}


resource "azurerm_lighthouse_assignment" "this" {
  for_each = local.target_subscription_ids

  scope                    = "/subscriptions/${each.value}"
  lighthouse_definition_id = azurerm_lighthouse_definition.this.id

  depends_on = [terraform_data.resource_provider_registration]
}


########################################################
# AccuKnox service principal
########################################################

locals {
  accuknox_principal_required = var.enable_graph_permissions || var.enable_aiml_access
}

data "azuread_service_principal" "accuknox" {
  count     = local.accuknox_principal_required ? 1 : 0
  client_id = trimspace(var.accuknox_app_client_id)
}


########################################################
# Microsoft Graph application permissions
########################################################

data "azuread_service_principal" "msgraph" {
  count     = var.enable_graph_permissions ? 1 : 0
  client_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
}

resource "azuread_app_role_assignment" "accuknox_graph" {
  for_each = var.enable_graph_permissions ? toset([for r in var.graph_app_role_ids : lower(trimspace(r))]) : toset([])

  app_role_id         = each.value
  principal_object_id = data.azuread_service_principal.accuknox[0].object_id
  resource_object_id  = data.azuread_service_principal.msgraph[0].object_id
}


########################################################
# AI/ML scanning access
########################################################

locals {
  aiml_enabled            = var.enable_aiml_access
  ml_scanner_role_enabled = var.enable_aiml_access && var.enable_ml_scanner_custom_role

  aiml_role_definition_ids = toset([for r in local.aiml_builtin_role_definition_ids : lower(r)])

  aiml_role_assignments = local.aiml_enabled ? {
    for pair in setproduct(local.target_subscription_ids, local.aiml_role_definition_ids) :
    "${pair[0]}/${pair[1]}" => {
      subscription_id    = pair[0]
      role_definition_id = pair[1]
    }
  } : {}

  # Preferred scope for a newly-created ML Scanner role.
  ml_scanner_desired_role_scope = local.uses_root_management_group ? "/providers/Microsoft.Management/managementGroups/${local.root_management_group_id}" : "/subscriptions/${local.context_subscription_id}"
}

# Discover an existing custom role with the same tenant-wide name.
data "external" "ml_scanner_existing_role" {
  count = local.ml_scanner_role_enabled ? 1 : 0

  program = ["bash", "-c", <<-EOT
    set -uo pipefail
    role_name=${jsonencode(var.ml_scanner_role_name)}
    role_id=$(az role definition list \
      --name "$role_name" \
      --custom-role-only true \
      --query "[0].id" -o tsv 2>/dev/null || true)
    printf '{"id":"%s"}\n' "$role_id"
  EOT
  ]
}

locals {
  ml_scanner_existing_role_resource_id = local.ml_scanner_role_enabled ? trimspace(try(data.external.ml_scanner_existing_role[0].result.id, "")) : ""

  ml_scanner_existing_role_guid = local.ml_scanner_existing_role_resource_id == "" ? "" : lower(element(reverse(split("/", local.ml_scanner_existing_role_resource_id)), 0))

  ml_scanner_existing_role_scope = local.ml_scanner_existing_role_resource_id == "" ? "" : trimsuffix(
    local.ml_scanner_existing_role_resource_id,
    "/providers/Microsoft.Authorization/roleDefinitions/${local.ml_scanner_existing_role_guid}",
  )

  # Keep the original Azure scope when adopting an existing role; otherwise use the desired scope.
  ml_scanner_role_scope = local.ml_scanner_existing_role_scope != "" ? local.ml_scanner_existing_role_scope : local.ml_scanner_desired_role_scope

  # A management-group scope covers its child subscriptions. A subscription-scoped existing
  # role needs the target subscriptions listed explicitly.
  ml_scanner_assignable_scopes = startswith(lower(local.ml_scanner_role_scope), "/providers/microsoft.management/managementgroups/") ? [
    local.ml_scanner_role_scope
    ] : distinct(concat(
      [local.ml_scanner_role_scope],
      [for s in sort(tolist(local.target_subscription_ids)) : "/subscriptions/${s}"],
  ))

  ml_scanner_role_imports = local.ml_scanner_existing_role_resource_id != "" ? {
    existing = "${local.ml_scanner_existing_role_resource_id}|${local.ml_scanner_existing_role_scope}"
  } : {}
}

# Discover existing direct AI/ML assignments so a rerun can adopt them into state.
data "azurerm_role_assignments" "accuknox_aiml_existing" {
  for_each = local.aiml_enabled ? local.target_subscription_ids : toset([])

  scope          = "/subscriptions/${each.value}"
  principal_id   = data.azuread_service_principal.accuknox[0].object_id
  limit_at_scope = true
}

locals {
  aiml_existing_imports = {
    for item in flatten([
      for subscription_id, result in data.azurerm_role_assignments.accuknox_aiml_existing : [
        for assignment in result.role_assignments : {
          key = "${subscription_id}/${lower(element(reverse(split("/", assignment.role_definition_id)), 0))}"
          id  = assignment.role_assignment_id
        }
        if contains(
          local.aiml_role_definition_ids,
          lower(element(reverse(split("/", assignment.role_definition_id)), 0))
        )
      ]
    ]) : item.key => item.id
  }
}

# Existing matching assignments are imported automatically; missing ones are created.
import {
  for_each = local.aiml_existing_imports
  to       = azurerm_role_assignment.accuknox_aiml[each.key]
  id       = each.value
}

resource "azurerm_role_assignment" "accuknox_aiml" {
  for_each = local.aiml_role_assignments

  scope              = "/subscriptions/${each.value.subscription_id}"
  role_definition_id = "/subscriptions/${each.value.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/${each.value.role_definition_id}"
  principal_id       = data.azuread_service_principal.accuknox[0].object_id
  principal_type     = "ServicePrincipal"
}

# Adopt the existing tenant-wide custom role when present; otherwise create it.
import {
  for_each = local.ml_scanner_role_imports
  to       = azurerm_role_definition.accuknox_ml_scanner[0]
  id       = each.value
}

resource "azurerm_role_definition" "accuknox_ml_scanner" {
  count = local.ml_scanner_role_enabled ? 1 : 0

  name        = var.ml_scanner_role_name
  scope       = local.ml_scanner_role_scope
  description = "AccuKnox AIML: AI asset inventory and red teaming across Azure Machine Learning, Azure OpenAI, and classic and new Foundry models and agents"

  permissions {
    actions          = local.custom_role_permissions.actions
    data_actions     = local.custom_role_permissions.data_actions
    not_actions      = []
    not_data_actions = []
  }

  assignable_scopes = local.ml_scanner_assignable_scopes
}

# Allow Azure RBAC time to propagate the custom role before assignments.
resource "time_sleep" "ml_scanner_role_propagation" {
  count = local.ml_scanner_role_enabled ? 1 : 0

  create_duration = var.role_definition_propagation_delay

  triggers = {
    role_definition_id = azurerm_role_definition.accuknox_ml_scanner[0].role_definition_resource_id
    assignable_scopes  = join(",", local.ml_scanner_assignable_scopes)
  }
}

locals {
  ml_scanner_assignment_existing_imports = local.ml_scanner_existing_role_guid != "" ? {
    for item in flatten([
      for subscription_id, result in data.azurerm_role_assignments.accuknox_aiml_existing : [
        for assignment in result.role_assignments : {
          key = subscription_id
          id  = assignment.role_assignment_id
        }
        if lower(element(reverse(split("/", assignment.role_definition_id)), 0)) == local.ml_scanner_existing_role_guid
      ]
    ]) : item.key => item.id
  } : {}
}

# Adopt existing ML Scanner assignments as well, preventing rerun 409 conflicts.
import {
  for_each = local.ml_scanner_assignment_existing_imports
  to       = azurerm_role_assignment.accuknox_ml_scanner[each.key]
  id       = each.value
}

resource "azurerm_role_assignment" "accuknox_ml_scanner" {
  for_each = local.ml_scanner_role_enabled ? local.target_subscription_ids : toset([])

  scope              = "/subscriptions/${each.value}"
  role_definition_id = "/subscriptions/${each.value}/providers/Microsoft.Authorization/roleDefinitions/${azurerm_role_definition.accuknox_ml_scanner[0].role_definition_id}"
  principal_id       = data.azuread_service_principal.accuknox[0].object_id
  principal_type     = "ServicePrincipal"

  depends_on = [time_sleep.ml_scanner_role_propagation]
}


########################################################
# Power Platform (Dataverse) registration via REST API
# Uses BAP for discovery and Dataverse REST APIs for app-user registration.
########################################################

data "external" "powerplatform_environments" {
  count = var.enable_powerplatform_registration ? 1 : 0

  program = ["timeout", "--kill-after=5s", "${var.powerplatform_discovery_timeout_seconds}s", "bash", "-c", <<-EOT
    set -euo pipefail
    trap 'echo "Power Platform discovery exceeded its total time limit; no inventory returned" >&2; exit 124' TERM
    page=0
    command -v jq >/dev/null || { echo "jq is required for Power Platform discovery" >&2; exit 1; }
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    touch "$work/environments" "$work/visited"
    url="https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments?api-version=$1&%24expand=properties.linkedEnvironmentMetadata"
    while [ -n "$url" ]; do
      case "$url" in
        https://api.bap.microsoft.com/*) ;;
        *) echo "Unexpected BAP continuation URL" >&2; exit 1 ;;
      esac
      if grep -Fxq "$url" "$work/visited"; then
        echo "Repeated BAP continuation URL" >&2
        exit 1
      fi
      printf '%s\n' "$url" >> "$work/visited"
      page=$((page + 1))
      if timeout --foreground --kill-after=5s "$2" az rest --method get --url "$url" \
        --resource "https://api.bap.microsoft.com/" --only-show-errors -o json > "$work/page"; then
        :
      else
        rc=$?
        echo "Power Platform discovery failed on page $page (exit $rc, per-request limit $2 seconds); no inventory returned" >&2
        exit "$rc"
      fi
      jq -e '.value | type == "array"' "$work/page" >/dev/null
      jq -c '.value[] | select(.properties.linkedEnvironmentMetadata.instanceUrl != null and .properties.linkedEnvironmentMetadata.instanceUrl != "") |
        {id: .name, name: .properties.displayName, url: .properties.linkedEnvironmentMetadata.instanceUrl, state: .properties.linkedEnvironmentMetadata.instanceState}' \
        "$work/page" >> "$work/environments"
      url=$(jq -r '.nextLink // ."@odata.nextLink" // empty' "$work/page")
    done
    jq -s '{envs: (unique_by(.id) | tojson)}' "$work/environments"
  EOT
    , "powerplatform-discovery", var.powerplatform_api_version, tostring(var.powerplatform_request_timeout_seconds)
  ]
}

locals {
  pp_all_envs = var.enable_powerplatform_registration ? jsondecode(
    data.external.powerplatform_environments[0].result.envs
  ) : []

  # Keep resource membership stable when environment health changes.
  dataverse_envs = {
    for env in local.pp_all_envs :
    env.id => {
      id    = env.id
      name  = env.name
      url   = trimsuffix(env.url, "/")
      state = coalesce(try(env.state, null), "Unknown")
    }
    if var.powerplatform_environment_selection == "all" ||
    contains(var.only_environment_display_names, env.name)
  }
}
resource "terraform_data" "pp_app_user" {
  for_each = local.dataverse_envs

  input = {
    url             = each.value.url
    env_id          = each.value.id
    env_name        = each.value.name
    app_id          = trimspace(var.accuknox_app_client_id)
    role_name       = var.dataverse_security_role_name
    state           = each.value.state
    skip            = contains(var.powerplatform_skip_environment_ids, each.key)
    timeout_seconds = var.powerplatform_request_timeout_seconds
  }

  triggers_replace = {
    url       = each.value.url
    app_id    = trimspace(var.accuknox_app_client_id)
    role_name = var.dataverse_security_role_name
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    quiet       = true

    environment = {
      PP_URL     = self.input.url
      PP_APP     = self.input.app_id
      PP_ROLE    = self.input.role_name
      PP_ENV     = self.input.env_name
      PP_STATE   = self.input.state
      PP_SKIP    = tostring(self.input.skip)
      PP_TIMEOUT = tostring(self.input.timeout_seconds)
    }

    command = <<-EOT
      set -euo pipefail
      base="$PP_URL/api/data/v9.2"
      umask 077
      work=$(mktemp -d)
      err="$work/error"
      touch "$err"
      trap 'rm -rf "$work"' EXIT

      authenticate() {
        command -v curl >/dev/null && command -v jq >/dev/null || fail "curl and jq are required"
        local token
        token=$(timeout --kill-after=5s "$PP_TIMEOUT" az account get-access-token \
          --resource "$PP_URL" --query accessToken -o tsv --only-show-errors 2>"$err") || fail "token acquisition failed"
        [ -n "$token" ] || fail "token acquisition returned an empty token"
        printf 'Authorization: Bearer %s\n' "$token" > "$work/auth"
      }
      # rest METHOD URL [jq filter] [JSON body]
      # Do not retry writes with unknown outcomes.
      rest() {
        local method="$1" url="$2" query="$${3:-empty}" body="$${4:-}" status rc
        local args=()
        [ -z "$body" ] || args+=(--data-binary "$body")
        : > "$err"
        status=$(curl --disable --silent --show-error --globoff --proto '=https' \
          --connect-timeout "$PP_TIMEOUT" --max-time "$PP_TIMEOUT" \
          --request "$method" --url "$url" \
          --header "@$work/auth" --header 'Accept: application/json' \
          --header 'Content-Type: application/json' --header 'OData-Version: 4.0' \
          --header 'Prefer: return=representation' \
          --output "$work/response" --write-out '%%{http_code}' "$${args[@]}" 2>"$err") || {
            rc=$?
            case "$rc" in
              6|7|28) printf 'Unavailable transport (curl %s)\n' "$rc" >> "$err" ;;
            esac
            return "$rc"
          }
        case "$status" in
          2??) ;;
          *) printf 'HTTP %s\n' "$status" > "$err"
             cat "$work/response" >> "$err"
             return 1 ;;
        esac
        if [ "$method" = GET ]; then
          jq -e '.value | type == "array"' "$work/response" >/dev/null 2>"$err" || {
            echo 'Invalid Dataverse collection response' >> "$err"
            return 1
          }
        fi
        [ "$query" = empty ] || jq -r "$query" "$work/response" 2>"$err"
      }
      fail() {
        echo "ERROR Power Platform: $PP_ENV - $1" >&2
        cat "$err" >&2
        exit 1
      }
      read_failed() {
        if [ "$1" = 124 ] || [ "$1" = 137 ] || grep -qiE '^HTTP (403|404|502|503|504)$|^Unavailable transport' "$err"; then
          echo "SKIP Power Platform: $PP_ENV - unavailable or access denied ($2); use -replace to retry" >&2
          cat "$err" >&2
          exit 0
        fi
        fail "$2"
      }

      if [ "$PP_SKIP" = true ]; then
        echo "SKIP Power Platform: $PP_ENV - explicitly excluded from registration"
        exit 0
      fi
      case "$PP_STATE" in
        Ready|Unknown) ;;
        *) echo "SKIP Power Platform: $PP_ENV - Dataverse state $PP_STATE; use -replace to retry"; exit 0 ;;
      esac

      authenticate

      role_literal=$(printf '%s' "$PP_ROLE" | sed "s/'/''/g")
      role_encoded=""
      export LC_ALL=C
      for ((i=0; i<$${#role_literal}; i++)); do
        c="$${role_literal:i:1}"
        printf -v hex '%%%02X' "'$c"
        role_encoded+="$hex"
      done
      # Soft-deleted users can block registration; check them first.
      user=$(rest GET "$base/systemusers?%24select=systemuserid,_businessunitid_value,isdisabled,deletedstate&%24filter=applicationid%20eq%20$PP_APP&%24orderby=deletedstate%20desc&%24top=1" \
        '.value[0] // empty | if .deletedstate == 1 then "SOFT_DELETED" elif .deletedstate == 0 then [.systemuserid, ._businessunitid_value, .isdisabled] | @tsv else error("Unknown user deleted state") end') || read_failed "$?" "app user lookup failed"
      if [ "$user" = SOFT_DELETED ]; then
        echo "SKIP Power Platform: $PP_ENV - soft-deleted application user requires administrator resolution; use -replace after resolution to retry" >&2
        exit 0
      fi
      uid=""; bu=""; disabled=""; roleid=""
      if [ -n "$user" ]; then
        IFS=$'\t' read -r uid bu disabled <<< "$user"
        roleid=$(rest GET "$base/roles?%24select=roleid&%24filter=name%20eq%20'$role_encoded'%20and%20_businessunitid_value%20eq%20$bu" \
          '.value[0].roleid // empty') || read_failed "$?" "role lookup failed"
      else
        unit=$(rest GET "$base/businessunits?%24select=businessunitid&%24filter=parentbusinessunitid%20eq%20null&%24expand=business_unit_roles(%24select=roleid;%24filter=name%20eq%20'$role_encoded')" \
          '.value[0] // empty | [.businessunitid, (.business_unit_roles[0].roleid // "")] | @tsv') || read_failed "$?" "business unit and role lookup failed"
        [ -n "$unit" ] || fail "root business unit not found"
        IFS=$'\t' read -r bu roleid <<< "$unit"
        [ -n "$bu" ] || fail "root business unit not found"
      fi
      [ -n "$roleid" ] || fail "role '$PP_ROLE' not found in business unit $bu"

      if [ -z "$uid" ]; then
        if uid=$(rest POST "$base/systemusers?%24select=systemuserid" \
          '.systemuserid // empty' \
          "{\"applicationid\":\"$PP_APP\",\"businessunitid@odata.bind\":\"/businessunits($bu)\",\"systemuserroles_association@odata.bind\":[\"/roles($roleid)\"]}"); then
          [ -n "$uid" ] || fail "app user creation returned no ID"
          echo "OK Power Platform: $PP_ENV"
          exit 0
        elif grep -qiE '^HTTP 403$' "$err"; then
          echo "SKIP Power Platform: $PP_ENV - app user registration denied; use -replace to retry" >&2
          cat "$err" >&2
          exit 0
        else
          fail "app user creation failed"
        fi
      elif [ "$disabled" = True ] || [ "$disabled" = true ]; then
        if ! rest PATCH "$base/systemusers($uid)" \
          empty '{"isdisabled":false}'; then
          if grep -q '^HTTP 403$' "$err"; then
            echo "SKIP Power Platform: $PP_ENV - activation denied; user remains disabled; use -replace to retry" >&2
            cat "$err" >&2
            exit 0
          fi
          if grep -q '^HTTP 400$' "$err" && jq -e '.error.code == "0x80048357"' "$work/response" >/dev/null 2>&1; then
            echo "SKIP Power Platform: $PP_ENV - application user was soft-deleted; use -replace after administrator resolution to retry" >&2
            cat "$err" >&2
            exit 0
          fi
          fail "activation failed"
        fi
      fi

      if ! rest POST "$base/systemusers($uid)/systemuserroles_association/%24ref" \
        empty \
        "{\"@odata.id\":\"$base/roles($roleid)\"}"; then
        cat "$err" >&2
        assigned=$(rest GET "$base/systemusers($uid)/systemuserroles_association?%24select=roleid&%24filter=roleid%20eq%20$roleid" \
          '.value[0].roleid // empty') || fail "role assignment verification failed"
        [ "$assigned" = "$roleid" ] || fail "role assignment failed"
      fi
      echo "OK Power Platform: $PP_ENV"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    quiet       = true

    environment = {
      PP_URL  = self.input.url
      PP_APP  = self.input.app_id
      PP_ROLE = self.input.role_name
      PP_ENV  = self.input.env_name
      # Support resources created before timeout was stored in state.
      PP_TIMEOUT = tostring(try(self.input.timeout_seconds, 30))
    }

    command = <<-EOT
      set -euo pipefail
      base="$PP_URL/api/data/v9.2"
      umask 077
      work=$(mktemp -d)
      err="$work/error"
      touch "$err"
      trap 'rm -rf "$work"' EXIT
      authenticate() {
        command -v curl >/dev/null && command -v jq >/dev/null || fail "curl and jq are required"
        local token
        token=$(timeout --kill-after=5s "$PP_TIMEOUT" az account get-access-token \
          --resource "$PP_URL" --query accessToken -o tsv --only-show-errors 2>"$err") || fail "token acquisition failed"
        [ -n "$token" ] || fail "token acquisition returned an empty token"
        printf 'Authorization: Bearer %s\n' "$token" > "$work/auth"
      }
      # rest METHOD URL [jq filter] [JSON body]
      # Do not retry writes with unknown outcomes.
      rest() {
        local method="$1" url="$2" query="$${3:-empty}" body="$${4:-}" status rc
        local args=()
        [ -z "$body" ] || args+=(--data-binary "$body")
        : > "$err"
        status=$(curl --disable --silent --show-error --globoff --proto '=https' \
          --connect-timeout "$PP_TIMEOUT" --max-time "$PP_TIMEOUT" \
          --request "$method" --url "$url" \
          --header "@$work/auth" --header 'Accept: application/json' \
          --header 'Content-Type: application/json' --header 'OData-Version: 4.0' \
          --header 'Prefer: return=representation' \
          --output "$work/response" --write-out '%%{http_code}' "$${args[@]}" 2>"$err") || {
            rc=$?
            case "$rc" in
              6|7|28) printf 'Unavailable transport (curl %s)\n' "$rc" >> "$err" ;;
            esac
            return "$rc"
          }
        case "$status" in
          2??) ;;
          *) printf 'HTTP %s\n' "$status" > "$err"
             cat "$work/response" >> "$err"
             return 1 ;;
        esac
        if [ "$method" = GET ]; then
          jq -e '.value | type == "array"' "$work/response" >/dev/null 2>"$err" || {
            echo 'Invalid Dataverse collection response' >> "$err"
            return 1
          }
        fi
        [ "$query" = empty ] || jq -r "$query" "$work/response" 2>"$err"
      }
      fail() {
        echo "ERROR Power Platform: $PP_ENV - $1; cleanup incomplete" >&2
        cat "$err" >&2
        exit 1
      }

      authenticate

      user=$(rest GET "$base/systemusers?%24select=systemuserid,isdisabled&%24filter=applicationid%20eq%20$PP_APP%20and%20deletedstate%20eq%200" \
        '.value[0] // empty | if (.systemuserid | type) != "string" or (.isdisabled | type) != "boolean" then error("Invalid user ID or disabled status") else [.systemuserid, .isdisabled] | @tsv end') || fail "app user lookup failed"
      if [ -z "$user" ]; then
        echo "SKIP Power Platform: $PP_ENV - app user absent"
        exit 0
      fi
      IFS=$'\t' read -r uid disabled <<< "$user"

      if [ "$disabled" != true ]; then
        rest PATCH "$base/systemusers($uid)" \
          empty '{"isdisabled":true}' || fail "disable failed"
      fi

      role_literal=$(printf '%s' "$PP_ROLE" | sed "s/'/''/g")
      role_encoded=""
      export LC_ALL=C
      for ((i=0; i<$${#role_literal}; i++)); do
        c="$${role_literal:i:1}"
        printf -v hex '%%%02X' "'$c"
        role_encoded+="$hex"
      done

      roleid=$(rest GET "$base/systemusers($uid)/systemuserroles_association?%24select=roleid,name&%24filter=name%20eq%20'$role_encoded'" \
        '.value[0].roleid // empty') || fail "role lookup failed"

      if [ -n "$roleid" ]; then
        rest DELETE "$base/systemusers($uid)/systemuserroles_association($roleid)/%24ref" \
          || fail "role removal failed"
      fi

      echo "OK Power Platform disabled, role '$PP_ROLE' removed, app user retained: $PP_ENV"
    EOT
  }
}

resource "azurerm_policy_definition" "auto_onboard" {
  for_each = local.policy_scope_management_group_ids

  name                = var.policy_definition_name
  display_name        = "Auto-assign AccuKnox Lighthouse to new subscriptions"
  description         = "Creates a Lighthouse assignment for the shared AccuKnox registration definition in every subscription that does not have one."
  policy_type         = "Custom"
  mode                = "All"
  management_group_id = "/providers/Microsoft.Management/managementGroups/${each.value}"

  metadata = jsonencode({
    category = "Lighthouse"
    version  = "2.0.0"
  })

  parameters = jsonencode({
    lighthouseDefinitionId = {
      type = "String"
      metadata = {
        displayName = "Lighthouse registration definition ID"
        description = "Resource ID of the shared AccuKnox Lighthouse registration definition."
      }
    }
  })

  policy_rule = jsonencode({
    if = {
      field  = "type"
      equals = "Microsoft.Resources/subscriptions"
    }
    then = {
      effect = "deployIfNotExists"
      details = {
        type              = "Microsoft.ManagedServices/registrationAssignments"
        deploymentScope   = "Subscription"
        existenceScope    = "Subscription"
        evaluationDelay   = "AfterProvisioning"
        roleDefinitionIds = [local.owner_role_definition_id]
        existenceCondition = {
          allOf = [
            {
              field  = "type"
              equals = "Microsoft.ManagedServices/registrationAssignments"
            },
            {
              field  = "Microsoft.ManagedServices/registrationAssignments/registrationDefinitionId"
              equals = "[parameters('lighthouseDefinitionId')]"
            }
          ]
        }
        deployment = {
          location = var.deployment_location
          properties = {
            mode = "incremental"
            parameters = {
              lighthouseDefinitionId = {
                value = "[parameters('lighthouseDefinitionId')]"
              }
            }
            template = {
              "$schema"      = "https://schema.management.azure.com/schemas/2018-05-01/subscriptionDeploymentTemplate.json#"
              contentVersion = "1.0.0.0"
              parameters = {
                lighthouseDefinitionId = { type = "string" }
              }
              variables = {
                assignmentName = "[guid(parameters('lighthouseDefinitionId'), subscription().subscriptionId)]"
              }
              resources = [
                {
                  type       = "Microsoft.ManagedServices/registrationAssignments"
                  apiVersion = "2020-02-01-preview"
                  name       = "[variables('assignmentName')]"
                  properties = {
                    registrationDefinitionId = "[parameters('lighthouseDefinitionId')]"
                  }
                }
              ]
            }
          }
        }
      }
    }
  })
}

resource "azurerm_management_group_policy_assignment" "auto_onboard" {
  for_each = local.policy_scope_management_group_ids

  name                 = var.policy_assignment_name
  display_name         = "AccuKnox Lighthouse auto-onboarding (${each.value})"
  description          = "Delegates every subscription under this management group to AccuKnox via Azure Lighthouse. Excluded scopes are never delegated."
  management_group_id  = "/providers/Microsoft.Management/managementGroups/${each.value}"
  policy_definition_id = azurerm_policy_definition.auto_onboard[each.key].id
  location             = var.policy_assignment_location
  enforce              = true
  not_scopes           = local.policy_not_scopes

  identity {
    type = "SystemAssigned"
  }

  parameters = jsonencode({
    lighthouseDefinitionId = { value = azurerm_lighthouse_definition.this.id }
  })
}


resource "azurerm_role_assignment" "auto_onboard_owner" {
  for_each = local.policy_scope_management_group_ids

  scope              = "/providers/Microsoft.Management/managementGroups/${each.value}"
  role_definition_id = local.owner_role_definition_id
  principal_id       = azurerm_management_group_policy_assignment.auto_onboard[each.key].identity[0].principal_id
  principal_type     = "ServicePrincipal"
  description        = "AccuKnox Lighthouse auto-onboarding policy identity"
}

resource "terraform_data" "auto_onboard_remediation" {
  for_each = local.policy_scope_management_group_ids

  triggers_replace = [azurerm_management_group_policy_assignment.auto_onboard[each.key].id]

  provisioner "local-exec" {
    command = "az policy remediation create --name \"accuknox-lighthouse-${formatdate("YYYYMMDD-hhmmss", timestamp())}\" --policy-assignment \"${azurerm_management_group_policy_assignment.auto_onboard[each.key].id}\" --management-group \"${each.value}\" --resource-discovery-mode ExistingNonCompliant"
  }

  depends_on = [
    azurerm_role_assignment.auto_onboard_owner,
    azurerm_lighthouse_assignment.this,
  ]
}

output "mode" {
  description = "Subscription selection mode in effect."
  value       = var.mode
}

output "lighthouse_definition_id" {
  description = "Resource ID of the shared Lighthouse registration definition."
  value       = azurerm_lighthouse_definition.this.id
}

output "onboarded_subscription_ids" {
  description = "Subscriptions that receive a Lighthouse assignment from this run."
  value       = sort(tolist(local.target_subscription_ids))
}

output "skipped_inactive_subscriptions" {
  description = "Subscriptions selected by the mode rules but skipped because of their state (Disabled / Warned / Deleted)."
  value       = local.skipped_inactive_subscriptions
}

output "effective_exclusions" {
  description = "Exclusions applied to the direct assignments and to the auto-onboarding policy (not_scopes)."
  value = {
    subscription_ids     = sort(tolist(local.excluded_subscription_ids))
    management_group_ids = var.mode == "exclude" ? sort(tolist(local.excluded_management_group_ids)) : []
  }
}

output "auto_onboarding_policy_assignment_ids" {
  description = "Policy assignment IDs keyed by management group (empty when enable_auto_policy = false)."
  value       = { for mg, pa in azurerm_management_group_policy_assignment.auto_onboard : mg => pa.id }
}

output "granted_graph_app_role_ids" {
  description = "Microsoft Graph app role IDs granted to the AccuKnox service principal (empty when enable_graph_permissions = false)."
  value       = sort([for a in azuread_app_role_assignment.accuknox_graph : a.app_role_id])
}

output "aiml_role_assignment_scopes" {
  description = "Subscriptions that received the direct AI/ML role assignments (empty when enable_aiml_access = false)."
  value       = local.aiml_enabled ? sort(tolist(local.target_subscription_ids)) : []
}

output "ml_scanner_role_definition_id" {
  description = "Resource ID of the custom ML scanner role definition (null when enable_ml_scanner_custom_role = false)."
  value       = one(azurerm_role_definition.accuknox_ml_scanner[*].role_definition_resource_id)
}


output "powerplatform_selected_environments" {
  description = "Environments selected for AccuKnox app-user registration (display name => Dataverse URL)."
  value       = { for id, env in local.dataverse_envs : env.name => env.url }
}

output "powerplatform_registration_resource_ids" {
  description = "Terraform resource IDs for the selected Dataverse app-user registration operations. Runtime API success/failure details are emitted by the local-exec provisioners."
  value       = { for id, registration in terraform_data.pp_app_user : id => registration.id }
}
