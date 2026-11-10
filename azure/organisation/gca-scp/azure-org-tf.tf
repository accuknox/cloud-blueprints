terraform {
  required_version = ">= 1.5.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
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

variable "managing_tenant_id" {
  description = "AccuKnox tenant ID (managing tenant of the Lighthouse delegation)."
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
  description = "AccuKnox principals and the roles delegated to them on every onboarded subscription."
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
  default     = "e918980b-80af-4890-b827-9ab79b3fac87"

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(var.context_subscription_id)))
    error_message = "context_subscription_id must be set to a subscription ID (GUID)."
  }
}

variable "management_group_id" {
  description = "Root management group ID (name, e.g. \"my-root-grp\", or the tenant ID for the Tenant Root Group). Required for mode = \"all\" and mode = \"exclude\"; ignored for mode = \"include\"."
  type        = string
  default     = "825a7bf3-be45-47e9-86d5-565d24b0a7fb"

  validation {
    condition     = trimspace(var.management_group_id) == "" || can(regex("(?i)^(/providers/microsoft\\.management/managementgroups/)?[a-z0-9._()-]+$", trimspace(var.management_group_id)))
    error_message = "management_group_id must be a management group name (letters, digits, '-', '_', '.', '(', ')')."
  }
}

variable "mode" {
  description = "Subscription selection mode: \"all\" (everything under management_group_id), \"include\" (only included_management_group_ids + include_extra_subscription_ids) or \"exclude\" (everything under management_group_id except excluded_management_groups, plus include_exception_subscription_ids)."
  type        = string
  default     = "exclude"

  validation {
    condition     = contains(["all", "include", "exclude"], var.mode)
    error_message = "mode must be one of \"all\", \"include\" or \"exclude\"."
  }
}

variable "excluded_subscription_ids" {
  description = "Subscription IDs that must never be onboarded. Applied in every mode after all other rules, so a subscription listed here is skipped even if it is under an included management group or listed in include_extra_subscription_ids / include_exception_subscription_ids. Also excluded from the auto-onboarding policy."
  type        = list(string)
  default     = ["e918980b-80af-4890-b827-9ab79b3fac87"]

  validation {
    condition     = alltrue([for s in var.excluded_subscription_ids : trimspace(s) == "" || can(regex("(?i)^(/subscriptions/)?[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(s)))])
    error_message = "excluded_subscription_ids entries must be subscription IDs (GUIDs)."
  }
}

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

variable "excluded_management_groups" {
  description = "EXCLUDE mode: management groups (descendants of management_group_id) whose subscriptions are NOT onboarded (recursively). They are also excluded from the auto-onboarding policy."
  type        = list(string)
  default     = ["mg-gr-2"]

  validation {
    condition     = alltrue([for m in var.excluded_management_groups : trimspace(m) == "" || can(regex("(?i)^(/providers/microsoft\\.management/managementgroups/)?[a-z0-9._()-]+$", trimspace(m)))])
    error_message = "excluded_management_groups entries must be management group names."
  }
}

variable "include_exception_subscription_ids" {
  description = "EXCLUDE mode: subscriptions to onboard anyway even though they sit under an excluded management group."
  type        = list(string)
  default     = ["0efab5d8-c8e0-41e3-9c67-9ec2dff68312"]

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

variable "accuknox_app_client_id" {
  description = "Client (application) ID of the AccuKnox enterprise app / service principal in the customer tenant."
  type        = string
  default     = "384d0c6d-8e35-489a-8833-346c5bbf2dbc"

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(var.accuknox_app_client_id)))
    error_message = "accuknox_app_client_id must be a client ID (GUID)."
  }
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

  candidate_subscription_ids = (
    var.mode == "all" ? local.root_subscription_ids :
    var.mode == "include" ? setunion(local.included_mg_subscription_ids, local.include_extra_subscription_ids) :
    setunion(setsubtract(local.root_subscription_ids, local.excluded_mg_subscription_ids), local.include_exception_subscription_ids)
  )

  selected_subscription_ids = setsubtract(local.candidate_subscription_ids, local.excluded_subscription_ids)

  inactive_subscription_states = ["Disabled", "Warned", "Deleted"]

  subscription_states = {
    for s in try(data.azurerm_subscriptions.visible[0].subscriptions, []) : lower(s.subscription_id) => s.state
  }

  skipped_inactive_subscriptions = {
    for id in local.selected_subscription_ids : id => local.subscription_states[id]
    if contains(local.inactive_subscription_states, lookup(local.subscription_states, id, "Enabled"))
  }

  target_subscription_ids = setsubtract(local.selected_subscription_ids, keys(local.skipped_inactive_subscriptions))

  policy_scope_management_group_ids = !var.enable_auto_policy ? toset([]) : (
    var.mode == "include" ? local.included_management_group_ids : toset([local.root_management_group_id])
  )

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

data "azuread_service_principal" "accuknox" {
  count     = var.enable_auto_policy ? 1 : 0
  client_id = trimspace(var.accuknox_app_client_id)
}

resource "azurerm_role_assignment" "accuknox_resource_policy_contributor" {
  count = var.enable_auto_policy ? 1 : 0

  scope                = "/providers/Microsoft.Management/managementGroups/${local.root_management_group_id}"
  role_definition_name = "Resource Policy Contributor"
  principal_id         = data.azuread_service_principal.accuknox[0].object_id
  principal_type       = "ServicePrincipal"
  description          = "AccuKnox tenant-wide policy support service principal"
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
