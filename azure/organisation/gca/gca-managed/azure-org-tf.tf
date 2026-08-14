########################################################
# Combined Terraform: main.tf, variables.tf, version.tf


########################################################
# Terraform Dependencies
########################################################

terraform {
  required_version = ">= 1.4.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = ">= 3.80.0"
    }
    azapi = {
      source  = "azure/azapi"
      version = ">= 1.12.0"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = ">= 2.47.0"
    }
    null = {
      source  = "hashicorp/null"
      version = ">= 3.0.0"
    }
  }
}

provider "azurerm" {
  features {}
  # Optional: let Terraform set a specific context subscription when needed.
  # Otherwise, azurerm will use Azure CLI default subscription or ARM_* env vars.
  subscription_id                 = var.context_subscription_id
  resource_provider_registrations = "none"
}

provider "azapi" {}



########################################################
# Variables
########################################################

variable "managing_tenant_id" {
  description = "AccuKnox tenant ID"
  type        = string
  default     = "3d64034d-3c3e-4959-b019-f15558be8a4e"
}

variable "accuknox_verification_token" {
  description = "Unique verification token provided by AccuKnox (DO NOT MODIFY)"
  type        = string
  default     = "AK-CNAPP-{{TOKEN}}"

  validation {
    condition     = can(regex("^AK-CNAPP-", var.accuknox_verification_token))
    error_message = "Verification token must start with 'AK-CNAPP-'"
  }
}



# User Provides
variable "management_group_id" {
  description = "Root management group ID where the policy will be assigned"
  type        = string
  default     = ""
}

variable "context_subscription_id" {
  description = "Subscription ID where the shared lighthouse definition will be created"
  type        = string
  default     = ""

  validation {
    condition     = var.context_subscription_id != null && var.context_subscription_id != ""
    error_message = "context_subscription_id must be provided"
  }
}



variable "offer_name" {
  description = "Lighthouse offer name"
  type        = string
  default     = "AccuKnox Delegation for CSPM Scanning"
}
variable "offer_description" {
  description = "Lighthouse offer description"
  type        = string
  default     = "Delegated read-only access via Lighthouse"
}



variable "authorizations" {
  description = "List of authorizations for Lighthouse"
  type = list(object({
    principal_id                  = string
    principal_display_name        = string
    role_definition_id            = string
    delegated_role_definition_ids = optional(list(string))
  }))
  default = [
    {
      principal_id           = "47e2ce34-c78d-4aaf-8f5f-300ec63c907f" # AccuKnox App Register
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



variable "mode" {
  description = "Onboarding mode: 'include' or 'exclude'"
  type        = string
  default     = "include"

  validation {
    condition     = contains(["include", "exclude"], var.mode)
    error_message = "mode must be 'include' or 'exclude'"
  }
}


# Global exclusions (applies to both modes)
variable "excluded_subscription_ids" {
  description = "Subscriptions to exclude globally"
  type        = list(string)
  default     = []
}


# Include mode variables (use when mode = "include")
variable "included_management_group_ids" {
  description = "Management groups to include (include mode only)"
  type        = list(string)
  default     = []
}

variable "include_extra_subscription_ids" {
  description = "Extra subscriptions to include outside of management groups (include mode only)"
  type        = list(string)
  default     = []
}


# Exclude mode variables (use when mode = "exclude")
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

variable "enable_auto_policy" {
  description = "Whether to create the Azure Policy (definition, assignment, role assignment, and remediation) that automatically onboards new subscriptions to the shared Lighthouse definition. Set to false to disable auto-onboarding."
  type        = bool
  default     = true
}



########################################################
# Data: Management Groups
########################################################

data "azurerm_management_group" "target" {
  name = var.management_group_id
}

data "azurerm_management_group" "included" {
  for_each = toset(local.filtered_included_management_group_ids)
  name     = each.value
}

########################################################
# Locals
########################################################

locals {
  mg_scope_id = data.azurerm_management_group.target.id

  # Transform authorizations to the format expected by azurerm_lighthouse_definition
  managed_by_authorizations = [
    for a in var.authorizations : merge(
      {
        principal_id           = a.principal_id
        principal_display_name = a.principal_display_name
        role_definition_id     = a.role_definition_id
      },
      length(coalesce(a.delegated_role_definition_ids, [])) > 0 ? {
        delegated_role_definition_ids = a.delegated_role_definition_ids
      } : {}
    )
  ]

  # Use context subscription for lighthouse definition
  customer_subscription_id = var.context_subscription_id
}

########################################################
# Data Sources for Subscription Discovery
########################################################

# Discover subscriptions per included management group using Resource Graph
data "external" "included_mg_subs" {
  for_each = toset(local.filtered_included_management_group_ids)
  program  = ["bash", "-c", <<-EOT
    result=$(az graph query -q "ResourceContainers | where type == 'microsoft.resources/subscriptions' | extend mgChain = properties.managementGroupAncestorsChain | where mgChain has '${each.value}' | project subscriptionId" -o json 2>/dev/null)
    if [ -z "$result" ]; then
      echo '{"subscriptions":"[]"}'
    else
      echo "$result" | jq -c '{subscriptions: ([.data[].subscriptionId] | @json)}'
    fi
  EOT
  ]
}

# Discover descendants under the root MG (exclude mode, recursive)
data "azapi_resource_list" "root_mg_descendants" {
  count     = var.mode == "exclude" ? 1 : 0
  parent_id = local.mg_scope_id
  type      = "Microsoft.Management/managementGroups/descendants@2020-05-01"
}

# Discover descendants under excluded MGs (to subtract recursively)
data "azapi_resource_list" "excluded_mg_descendants" {
  for_each  = var.mode == "exclude" ? toset(var.excluded_management_groups) : []
  parent_id = "/providers/Microsoft.Management/managementGroups/${each.value}"
  type      = "Microsoft.Management/managementGroups/descendants@2020-05-01"
}

########################################################
# Subscription ID Collections
########################################################

locals {
  # Map: subscription ID -> included MG ID it belongs to
  include_sub_to_mg = var.mode == "include" ? merge(
    [
      for mg, res in data.external.included_mg_subs : {
        for sub_id in try(jsondecode(res.result.subscriptions), []) :
        sub_id => mg
      }
    ]...
  ) : {}

  # Subscriptions under included MGs, excluding explicitly excluded subs
  include_mode_subscription_ids = var.mode == "include" ? [
    for sub_id, mg in local.include_sub_to_mg : sub_id
    if !contains(coalesce(var.excluded_subscription_ids, []), sub_id)
  ] : []

  # Exclude mode: compute subscription IDs under root MG (recursive) and subtract excluded MGs (recursive)
  root_mg_subscription_ids = var.mode == "exclude" ? [
    for item in try(data.azapi_resource_list.root_mg_descendants[0].output.value, []) : item.name
    if lower(try(item.type, "")) == "microsoft.management/managementgroups/subscriptions"
  ] : []

  excluded_mg_subscription_ids = var.mode == "exclude" ? flatten([
    for mg, res in data.azapi_resource_list.excluded_mg_descendants : [
      for item in try(res.output.value, []) : item.name
      if lower(try(item.type, "")) == "microsoft.management/managementgroups/subscriptions"
    ]
  ]) : []

  # Subscriptions to onboard under exclude mode
  exclude_mode_subscription_ids = var.mode == "exclude" ? [
    for sub_id in local.root_mg_subscription_ids : sub_id
    if !contains(coalesce(var.excluded_subscription_ids, []), sub_id)
    && !contains(local.excluded_mg_subscription_ids, sub_id)
    && !contains(coalesce(var.include_exception_subscription_ids, []), sub_id)
  ] : []

  # Filter out empty subscription IDs from extra subscriptions
  filtered_include_extra_subscription_ids = var.mode == "include" ? [
    for sub_id in var.include_extra_subscription_ids : sub_id
    if sub_id != ""
  ] : []

  # Filter out empty subscription IDs from exception subscriptions
  filtered_include_exception_subscription_ids = var.mode == "exclude" ? [
    for sub_id in var.include_exception_subscription_ids : sub_id
    if sub_id != ""
  ] : []

  # Filter out empty management group IDs
  filtered_included_management_group_ids = var.mode == "include" ? [
    for mg_id in var.included_management_group_ids : mg_id
    if mg_id != ""
  ] : []
}

########################################################
# Resource Provider Registration
########################################################

resource "azurerm_resource_provider_registration" "managed_services" {
  name = "Microsoft.ManagedServices"
}

########################################################
# Shared Lighthouse Registration Definition
########################################################

resource "azurerm_lighthouse_definition" "shared_lighthouse_definition" {
  depends_on = [azurerm_resource_provider_registration.managed_services]
  name               = "${var.offer_name} - ${var.accuknox_verification_token}"
  description        = var.offer_description
  managing_tenant_id = var.managing_tenant_id
  scope              = "/subscriptions/${local.customer_subscription_id}"

  dynamic "authorization" {
    for_each = var.authorizations
    content {
      principal_id                     = authorization.value.principal_id
      principal_display_name           = authorization.value.principal_display_name
      role_definition_id               = authorization.value.role_definition_id
      delegated_role_definition_ids    = try(authorization.value.delegated_role_definition_ids, null)
    }
  }
}

########################################################
# Lighthouse Assignments for Target Subscriptions
########################################################

# Assignment for extra subscriptions (include mode)
resource "azurerm_lighthouse_assignment" "include_extra_subscriptions" {
  count                    = length(local.filtered_include_extra_subscription_ids)
  scope                    = "/subscriptions/${local.filtered_include_extra_subscription_ids[count.index]}"
  lighthouse_definition_id = azurerm_lighthouse_definition.shared_lighthouse_definition.id
}

# Assignment for subscriptions under included management groups
resource "azurerm_lighthouse_assignment" "included_mg_subscriptions" {
  for_each                 = var.mode == "include" ? toset(local.include_mode_subscription_ids) : []
  scope                    = "/subscriptions/${each.value}"
  lighthouse_definition_id = azurerm_lighthouse_definition.shared_lighthouse_definition.id
}

# Assignment for exclude mode subscriptions
resource "azurerm_lighthouse_assignment" "exclude_mode_subscriptions" {
  for_each                 = var.mode == "exclude" ? toset(local.exclude_mode_subscription_ids) : []
  scope                    = "/subscriptions/${each.value}"
  lighthouse_definition_id = azurerm_lighthouse_definition.shared_lighthouse_definition.id
}

# Assignment for exception subscriptions (exclude mode)
resource "azurerm_lighthouse_assignment" "exclude_mode_exceptions" {
  count                    = length(local.filtered_include_exception_subscription_ids)
  scope                    = "/subscriptions/${local.filtered_include_exception_subscription_ids[count.index]}"
  lighthouse_definition_id = azurerm_lighthouse_definition.shared_lighthouse_definition.id
}

########################################################
# Policy for Automatic Assignment to New Subscriptions
########################################################

# Simple policy that creates lighthouse assignments for new subscriptions
# Create policy definition at each included management group to ensure scope compatibility
resource "azurerm_policy_definition" "auto_lighthouse_assignment" {
  for_each           = var.enable_auto_policy ? (var.mode == "include" ? toset(local.filtered_included_management_group_ids) : toset([var.management_group_id])) : []
  name               = var.policy_definition_name
  management_group_id = "/providers/Microsoft.Management/managementGroups/${each.value}"
  policy_type        = "Custom"
  mode               = "All"
  display_name       = "Auto-assign AccuKnox Lighthouse to new subscriptions"
  description        = "Automatically creates lighthouse assignments for new subscriptions using the shared definition"

  parameters = jsonencode({
    lighthouseDefinitionId = {
      type         = "string"
      defaultValue = azurerm_lighthouse_definition.shared_lighthouse_definition.id
    }
  })

  policy_rule = jsonencode({
    if = {
      field = "type"
      equals = "Microsoft.Resources/subscriptions"
    }
    then = {
      effect = "deployIfNotExists"
      details = {
        type              = "Microsoft.ManagedServices/registrationAssignments"
        deploymentScope   = "Subscription"
        existenceScope    = "Subscription"
        evaluationDelay   = "AfterProvisioning"
        roleDefinitionIds = ["/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635"] # Owner
        existenceCondition = {
          allOf = [
            {
              field = "type"
              equals = "Microsoft.ManagedServices/registrationAssignments"
            },
            {
              field = "Microsoft.ManagedServices/registrationAssignments/registrationDefinitionId"
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
              "$schema"      = "https://schema.management.azure.com/2018-05-01/subscriptionDeploymentTemplate.json#"
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

########################################################
# Policy Assignments for Automatic Onboarding
########################################################

# Policy assignment for include mode
resource "azurerm_management_group_policy_assignment" "auto_lighthouse_include" {
  count                = var.enable_auto_policy ? length(local.filtered_included_management_group_ids) : 0
  name                 = "${var.policy_assignment_name}-auto-${substr(lower(local.filtered_included_management_group_ids[count.index]), 0, 8)}"
  display_name         = "Auto Lighthouse Assignment - ${local.filtered_included_management_group_ids[count.index]}"
  management_group_id  = "/providers/Microsoft.Management/managementGroups/${local.filtered_included_management_group_ids[count.index]}"
  policy_definition_id = azurerm_policy_definition.auto_lighthouse_assignment[local.filtered_included_management_group_ids[count.index]].id
  location             = var.policy_assignment_location
  enforce              = true
  not_scopes           = [for sub in var.excluded_subscription_ids : "/subscriptions/${sub}"]

  identity { type = "SystemAssigned" }

  parameters = jsonencode({
    lighthouseDefinitionId = { value = azurerm_lighthouse_definition.shared_lighthouse_definition.id }
  })

  depends_on = [azurerm_lighthouse_definition.shared_lighthouse_definition]
}

resource "azurerm_role_assignment" "auto_policy_identity_owner_include" {
  count              = var.enable_auto_policy ? length(local.filtered_included_management_group_ids) : 0
  scope              = "/providers/Microsoft.Management/managementGroups/${local.filtered_included_management_group_ids[count.index]}"
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635" # Owner
  principal_id       = azurerm_management_group_policy_assignment.auto_lighthouse_include[count.index].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

########################################################
# Automatic Remediation for Include Mode
########################################################

# null_resource + local-exec: az policy remediation create is idempotent (ARM PUT) —
# creates if missing, updates if already exists, never errors on conflict
resource "null_resource" "auto_lighthouse_include_remediation" {
  for_each = var.enable_auto_policy ? toset(local.filtered_included_management_group_ids) : []

  triggers = {
    policy_assignment_id = azurerm_management_group_policy_assignment.auto_lighthouse_include[index(local.filtered_included_management_group_ids, each.value)].id
    mg_id                = each.value
  }

  provisioner "local-exec" {
    command = "az policy remediation create --name 'remediate-lighthouse-${lower(each.value)}' --policy-assignment '${azurerm_management_group_policy_assignment.auto_lighthouse_include[index(local.filtered_included_management_group_ids, each.value)].id}' --management-group '${each.value}'"
  }

  depends_on = [azurerm_role_assignment.auto_policy_identity_owner_include]
}

# Policy assignment for exclude mode
resource "azurerm_management_group_policy_assignment" "auto_lighthouse_exclude" {
  count                = var.enable_auto_policy && var.mode == "exclude" ? 1 : 0
  name                 = "${var.policy_assignment_name}-auto-exclude"
  display_name         = "Auto Lighthouse Assignment - Exclude Mode"
  management_group_id  = data.azurerm_management_group.target.id
  policy_definition_id = azurerm_policy_definition.auto_lighthouse_assignment[var.management_group_id].id
  location             = var.policy_assignment_location
  enforce              = true
  not_scopes = concat(
    [for mg in var.excluded_management_groups : "/providers/Microsoft.Management/managementGroups/${mg}"],
    [for sub in var.excluded_subscription_ids : "/subscriptions/${sub}"]
  )

  identity { type = "SystemAssigned" }

  parameters = jsonencode({
    lighthouseDefinitionId = { value = azurerm_lighthouse_definition.shared_lighthouse_definition.id }
  })

  depends_on = [azurerm_lighthouse_definition.shared_lighthouse_definition]
}

resource "azurerm_role_assignment" "auto_policy_identity_owner_exclude" {
  count              = var.enable_auto_policy && var.mode == "exclude" ? 1 : 0
  scope              = data.azurerm_management_group.target.id
  role_definition_id = "/providers/Microsoft.Authorization/roleDefinitions/8e3af657-a8ff-443c-a75c-2fe8c4bcb635" # Owner
  principal_id       = azurerm_management_group_policy_assignment.auto_lighthouse_exclude[0].identity[0].principal_id
  principal_type     = "ServicePrincipal"
}

########################################################
# Automatic Remediation for Exclude Mode
########################################################

resource "null_resource" "auto_lighthouse_exclude_remediation" {
  count = var.enable_auto_policy && var.mode == "exclude" ? 1 : 0

  triggers = {
    policy_assignment_id = azurerm_management_group_policy_assignment.auto_lighthouse_exclude[0].id
    mg_id                = var.management_group_id
  }

  provisioner "local-exec" {
    command = "az policy remediation create --name 'remediate-lighthouse-exclude' --policy-assignment '${azurerm_management_group_policy_assignment.auto_lighthouse_exclude[0].id}' --management-group '${var.management_group_id}'"
  }

  depends_on = [azurerm_role_assignment.auto_policy_identity_owner_exclude]
}

