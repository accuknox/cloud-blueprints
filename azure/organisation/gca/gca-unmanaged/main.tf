
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
