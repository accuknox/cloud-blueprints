variable "app_display_name" {
  type        = string
  default     = "Azure-Onboarding-App"
  description = "Display name of the Azure AD Application"
}
variable "subscription_id" {
  type        = string
  default     = ""
  description = "Azure Subscription ID. Leave empty to use current subscription"
}

provider "azurerm" {
    features {}
    skip_provider_registration = "true"
  }
  
  provider "azuread" {
    version = "~> 2.0"
  }
  
  resource "azuread_application" "accuknox" {
    display_name = var.app_display_name
  
    required_resource_access {
      resource_app_id = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
  
      resource_access {
        id   = "5778995a-e1bf-45b8-affa-663a9f3f4d04"  # Directory.Read.All
        type = "Scope"
      }
    }
  }
  
  resource "azuread_service_principal" "accuknox_sp" {
    application_id = azuread_application.accuknox.application_id
  }
  
  resource "random_password" "password" {
    length           = 32
    special          = true
    override_special = "_%@"
  }
  
  resource "azuread_service_principal_password" "client_secret" {
    service_principal_id = azuread_service_principal.accuknox_sp.id
  }
  
  data "azurerm_subscription" "current" {}
  
  resource "azurerm_role_assignment" "security_reader" {
    scope                = data.azurerm_subscription.current.id
    role_definition_name = "Reader"
    principal_id         = azuread_service_principal.accuknox_sp.object_id
  }
  
  data "azurerm_client_config" "current" {}
  
  output "application_id" {
    value = azuread_application.accuknox.application_id
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
    content = <<-EOT
  Application ID: "${azuread_application.accuknox.application_id}"
  Client Secret: ${azuread_service_principal_password.client_secret.value}
  Subscription ID: ${data.azurerm_subscription.current.id}
  Directory ID: ${data.azurerm_client_config.current.tenant_id}
    EOT
  }