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
    "Cognitive Services OpenAI User", # 5e0bd9bd-7b93-4f28-af87-19fc36ad61bd
    "Cognitive Services User",        # a97b65f3-24c7-4388-baec-2e87135dc908
    "Storage Blob Data Reader",       # 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
  ]
  description = "Built-in roles granted to the AccuKnox service principal for AI/ML scanning, in addition to Reader"
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
  description = "Custom role for ML & Cognitive services for AccuKnox"
  permissions {
    actions = [
      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action",
      "Microsoft.MachineLearningServices/workspaces/serverlessEndpoints/listKeys/action",
      "Microsoft.MachineLearningServices/workspaces/listStorageAccountKeys/action",
      "Microsoft.CognitiveServices/accounts/listKeys/action",
      "Microsoft.CognitiveServices/accounts/deployments/read",
      "Microsoft.MachineLearningServices/workspaces/datastores/listSecrets/action",
      "Microsoft.Storage/storageAccounts/listKeys/action"
    ]
  }
  assignable_scopes = [
    data.azurerm_subscription.current.id
  ]
}
resource "azurerm_role_assignment" "custom_ml_role_assignment" {
  scope              = data.azurerm_subscription.current.id
  role_definition_id = azurerm_role_definition.custom_accuknox_ml_role.role_definition_resource_id
  principal_id       = azuread_service_principal.accuknox_sp.object_id
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
