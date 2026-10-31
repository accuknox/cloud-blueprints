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

provider "azurerm" {
  features {}
  skip_provider_registration = true
  subscription_id            = var.subscription_id != "" ? var.subscription_id : null
}

provider "azuread" {}

# Microsoft Graph service principal: source of the application (app role) IDs
# below, so no permission GUIDs are hardcoded.
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

resource "azurerm_role_assignment" "security_reader" {
  scope                = data.azurerm_subscription.current.id
  role_definition_name = "Reader"
  principal_id         = azuread_service_principal.accuknox_sp.object_id
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
  value = data.azurerm_subscription.current.subscription_id
}

output "directory_id" {
  value = data.azurerm_client_config.current.tenant_id
}

output "graph_permissions" {
  description = "Microsoft Graph application permissions declared on the app; admin consent is granted here when enable_graph_permissions is true."
  value       = keys(local.graph_app_roles)
}

resource "local_file" "client_secret_and_app_sub_dir_file" {
  filename = "client_secret_and_app_sub_dir.txt"
  content  = <<-EOT
  Application ID: "${azuread_application.accuknox.client_id}"
  Client Secret: ${azuread_service_principal_password.client_secret.value}
  Subscription ID: ${data.azurerm_subscription.current.subscription_id}
  Directory ID: ${data.azurerm_client_config.current.tenant_id}
    EOT
}
