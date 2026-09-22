variable "app_display_name" {
  type        = string
  default     = "Azure-AIML-Onboarding-App_per_testing"
  description = "Display name of the Azure AD Application"
}
variable "subscription_id" {
  type        = string
  default     = ""
  description = "Azure Subscription ID. Leave empty to use current subscription"
}
variable "aiml_builtin_roles" {
  type = list(string)
  default = [
    "Storage Blob Data Reader", # 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
  ]
  description = "Built-in roles granted to the AccuKnox service principal for AI/ML scanning, in addition to Reader"
}
variable "aml_role_actions" {
  type = list(string)
  default = [
    "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action",
    "Microsoft.MachineLearningServices/workspaces/serverlessEndpoints/listKeys/action",
    "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/token/action",

    # classic Foundry / AML agents
    "Microsoft.MachineLearningServices/workspaces/agents/action",
  ]
  description = "Control-plane actions for the custom AML role"
}
variable "openai_role_data_actions" {
  type = list(string)
  default = [
    "Microsoft.CognitiveServices/accounts/OpenAI/files/read",
    "Microsoft.CognitiveServices/accounts/OpenAI/models/read",
    "Microsoft.CognitiveServices/accounts/OpenAI/deployments/read",
    "Microsoft.CognitiveServices/accounts/OpenAI/fine-tunes/read",

    "Microsoft.CognitiveServices/accounts/OpenAI/deployments/chat/completions/action",
    "Microsoft.CognitiveServices/accounts/OpenAI/deployments/embeddings/action",
  ]
  description = "Data-plane actions for the custom OpenAI role"
}
variable "foundry_role_data_actions" {
  type = list(string)
  default = [
    "Microsoft.CognitiveServices/accounts/AIServices/agents/read",
    "Microsoft.CognitiveServices/accounts/AIServices/deployments/read",
    "Microsoft.CognitiveServices/accounts/AIServices/connections/read",
    "Microsoft.CognitiveServices/accounts/AIServices/assets/read",
    "Microsoft.CognitiveServices/accounts/AIServices/index/entities/read",

    "Microsoft.CognitiveServices/accounts/AIServices/endpoints/interact/action",

    "Microsoft.CognitiveServices/accounts/MaaS/chat/completions/action",

    "Microsoft.CognitiveServices/accounts/AIServices/evaluations/read",

    # required only for querying Foundry red-team runs
    "Microsoft.CognitiveServices/accounts/AIServices/evaluations/write",
  ]
  description = "Data-plane actions for the custom AI Foundry role"
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
provider "azurerm" {
  features {}
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
}
provider "azuread" {}

resource "azuread_application" "accuknox" {
  display_name = var.app_display_name
  required_resource_access {
    resource_app_id = "00000003-0000-0000-c000-000000000000"
    resource_access {
      id   = "5778995a-e1bf-45b8-affa-663a9f3f4d04"
      type = "Scope"
    }
  }
}

resource "azuread_service_principal" "accuknox_sp" {
  client_id = azuread_application.accuknox.client_id
}
resource "azuread_service_principal_password" "client_secret" {
  service_principal_id = azuread_service_principal.accuknox_sp.id
  end_date             = timeadd(timestamp(), "8760h")
}
data "azurerm_subscription" "current" {
  subscription_id = var.subscription_id != "" ? var.subscription_id : null
}

resource "azurerm_role_assignment" "reader_role" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.accuknox_sp.object_id
}

resource "azurerm_role_assignment" "aiml_builtin_roles" {
  for_each             = toset(var.aiml_builtin_roles)
  scope                = data.azurerm_subscription.current.id
  role_definition_name = each.value
  principal_id         = azuread_service_principal.accuknox_sp.object_id

  # the service principal was just created, so skip the AAD existence check
  # that fails while the object is still replicating
  skip_service_principal_aad_check = true
}

resource "azurerm_role_definition" "custom_accuknox_ml_role" {
  name        = "AccuKnox-ML-Custom-Role_per_testing"
  scope       = data.azurerm_subscription.current.id
  description = "Custom role for Azure Machine Learning endpoint scanning for AccuKnox"
  permissions {
    actions = var.aml_role_actions
  }
  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}
resource "azurerm_role_assignment" "custom_ml_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.custom_accuknox_ml_role.role_definition_resource_id
  principal_id       = azuread_service_principal.accuknox_sp.object_id

  skip_service_principal_aad_check = true
}

# OpenAI and AI Foundry permissions are data actions, so they belong in
# data_actions - Azure rejects a role definition that lists them under actions
resource "azurerm_role_definition" "custom_accuknox_openai_role" {
  name        = "AccuKnox-OpenAI-Custom-Role_per_testing"
  scope       = data.azurerm_subscription.current.id
  description = "Custom role for Azure OpenAI inference and model inventory for AccuKnox"
  permissions {
    actions      = []
    data_actions = var.openai_role_data_actions
  }
  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}
resource "azurerm_role_assignment" "custom_openai_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.custom_accuknox_openai_role.role_definition_resource_id
  principal_id       = azuread_service_principal.accuknox_sp.object_id

  skip_service_principal_aad_check = true
}

resource "azurerm_role_definition" "custom_accuknox_foundry_role" {
  name        = "AccuKnox-Foundry-Custom-Role_per_testing"
  scope       = data.azurerm_subscription.current.id
  description = "Custom role for Azure AI Foundry agents, assets and model inference for AccuKnox"
  permissions {
    actions      = []
    data_actions = var.foundry_role_data_actions
  }
  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}
resource "azurerm_role_assignment" "custom_foundry_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.custom_accuknox_foundry_role.role_definition_resource_id
  principal_id       = azuread_service_principal.accuknox_sp.object_id

  skip_service_principal_aad_check = true
}

output "client_id" {
  value = azuread_application.accuknox.client_id
}
output "client_secret" {
  value     = azuread_service_principal_password.client_secret.value
  sensitive = true
}
output "subscription_id" {
  value = split("/", trim(data.azurerm_subscription.current.id, "/"))[1]
}
output "directory_id" {
  value = azuread_service_principal.accuknox_sp.application_tenant_id
}

resource "local_file" "client_secret_and_app_sub_dir_file" {
  filename = "client_secret_and_app_sub_dir.txt"
  content  = <<-EOT
Client ID: ${azuread_application.accuknox.client_id}
Client Secret: "${azuread_service_principal_password.client_secret.value}"
Subscription ID: "${split("/", trim(data.azurerm_subscription.current.id, "/"))[1]}"
Directory ID: "${azuread_service_principal.accuknox_sp.application_tenant_id}"
EOT
}
