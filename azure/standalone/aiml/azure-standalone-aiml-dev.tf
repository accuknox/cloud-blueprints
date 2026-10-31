variable "app_display_name" {
  type        = string
  default     = "Azure-AIML-Onboarding-App"
  description = "Display name of the Azure AD Application"
}
variable "subscription_id" {
  type        = string
  default     = ""
  description = "Azure Subscription ID. Leave empty to use current subscription"
}
variable "enable_graph_permissions" {
  type        = bool
  default     = true
  description = "Grant admin consent for the Microsoft Graph application permissions via app role assignments. Requires the operator to be a Global Administrator or Privileged Role Administrator in the tenant. Set to false to only declare the permissions on the app registration and grant admin consent manually in the portal."
}

terraform {
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 3.70"
    }
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.7"
    }
    random = {
      source = "hashicorp/random"
    }
    local = {
      source = "hashicorp/local"
    }
  }
}



data "azuread_service_principal" "msgraph" {
  client_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph
}

locals {
  graph_app_roles = {
    "Directory.Read.All"   = data.azuread_service_principal.msgraph.app_role_ids["Directory.Read.All"]
    "GroupMember.Read.All" = data.azuread_service_principal.msgraph.app_role_ids["GroupMember.Read.All"]
    "AuditLog.Read.All"    = data.azuread_service_principal.msgraph.app_role_ids["AuditLog.Read.All"]
    "Reports.Read.All"     = data.azuread_service_principal.msgraph.app_role_ids["Reports.Read.All"]
  }
}

# Built-in roles granted to the AccuKnox service principal at subscription scope.
locals {
  builtin_roles = [
    "Reader",                         # acdd72a7-3385-48ef-bd42-f606fba81ae7
    "Storage Blob Data Reader",       # 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
    "Cognitive Services Data Reader", # b59867f0-fa02-499b-be73-45a86b5b3e1c
    "Foundry Agent Consumer",         # eed3b665-ab3a-47b6-8f48-c9382fb1dad6
  ]
}

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

locals {
  shared_model_permissions = {
    actions = []
    data_actions = [
      "Microsoft.CognitiveServices/accounts/OpenAI/deployments/*/action",
    ]
  }
}

locals {
  custom_role_permissions = {
    actions = concat(
      local.classic_foundry_permissions.actions,
      local.new_foundry_permissions.actions,
      local.shared_model_permissions.actions,
    )
    data_actions = concat(
      local.classic_foundry_permissions.data_actions,
      local.new_foundry_permissions.data_actions,
      local.shared_model_permissions.data_actions,
    )
  }
}


provider "azurerm" {
  features {}
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
}
provider "azuread" {}

resource "azuread_application" "accuknox" {
  display_name = var.app_display_name
  required_resource_access {
    resource_app_id = data.azuread_service_principal.msgraph.client_id # Microsoft Graph

    dynamic "resource_access" {
      for_each = local.graph_app_roles
      content {
        id   = resource_access.value
        type = "Role"
      }
    }
  }
}

resource "azuread_service_principal" "accuknox_sp" {
  client_id = azuread_application.accuknox.client_id
}

resource "random_password" "password" {
  length           = 32
  special          = true
  override_special = "_%@"
}

resource "azuread_service_principal_password" "client_secret" {
  service_principal_id = azuread_service_principal.accuknox_sp.id
}

resource "azuread_app_role_assignment" "graph" {
  for_each            = { for name, id in local.graph_app_roles : name => id if var.enable_graph_permissions }
  app_role_id         = each.value
  principal_object_id = azuread_service_principal.accuknox_sp.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
}

resource "azurerm_role_assignment" "builtin" {
  for_each             = toset(local.builtin_roles)
  scope                = data.azurerm_subscription.current.id
  role_definition_name = each.value
  principal_id         = azuread_service_principal.accuknox_sp.object_id

  skip_service_principal_aad_check = true
}

resource "azurerm_role_definition" "custom_accuknox_aiml_role" {
  name        = "AccuKnox-AIML-Custom-Role"
  scope       = data.azurerm_subscription.current.id
  description = "Allows AccuKnox to inventory AI assets and run red teaming tests against Azure Machine Learning endpoints, Azure OpenAI deployments and assistants, and AI Foundry models and agents"

  permissions {
    actions      = local.custom_role_permissions.actions
    data_actions = local.custom_role_permissions.data_actions
  }

  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}

resource "azurerm_role_assignment" "custom_aiml_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.custom_accuknox_aiml_role.role_definition_resource_id
  principal_id       = azuread_service_principal.accuknox_sp.object_id

  skip_service_principal_aad_check = true
}

data "azurerm_client_config" "current" {}

output "application_id" {
  value = azuread_application.accuknox.client_id
}

output "client_secret" {
  value     = azuread_service_principal_password.client_secret.value
  sensitive = true
}

output "subscription_id" {
  value = data.azurerm_subscription.current.id
}

output "directory_id" {
  value = data.azurerm_client_config.current.tenant_id
}

resource "local_file" "client_secret_and_app_sub_dir_file" {
  filename = "client_secret_and_app_sub_dir.txt"
  content  = <<-EOT
Application ID: "${azuread_application.accuknox.client_id}"
Client Secret: ${azuread_service_principal_password.client_secret.value}
Subscription ID: ${data.azurerm_subscription.current.id}
Directory ID: ${data.azurerm_client_config.current.tenant_id}
  EOT
}
