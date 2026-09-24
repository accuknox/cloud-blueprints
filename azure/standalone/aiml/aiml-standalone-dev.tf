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



# Microsoft Graph delegated permissions declared on the app registration.
locals {
  graph_delegated_scopes = {
    "Directory.Read.All" = "5778995a-e1bf-45b8-affa-663a9f3f4d04"
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

# Classic Foundry: hub-based projects (Azure Machine Learning workspaces), classic Agent Service
# and Azure OpenAI Assistants. Reads come from Reader and Cognitive Services Data Reader.
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

# New Foundry: Foundry resources and projects. Agent endpoint calls (Responses API) come from
# Foundry Agent Consumer.
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

# Permissions for the AccuKnox custom role used for AI asset inventory and red teaming.
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
    resource_app_id = "00000003-0000-0000-c000-000000000000" # Microsoft Graph

    dynamic "resource_access" {
      for_each = local.graph_delegated_scopes
      content {
        id   = resource_access.value
        type = "Scope"
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
  name        = "AccuKnox-AIML-Custom-Role_TFASHISH"
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
