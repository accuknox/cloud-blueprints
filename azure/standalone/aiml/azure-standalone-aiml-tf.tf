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

# ---------------------------------------------------------------------------
# Variables
# ---------------------------------------------------------------------------

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

variable "builtin_roles" {
  type = list(string)
  default = [
    "Reader",                         # acdd72a7-3385-48ef-bd42-f606fba81ae7
    "Storage Blob Data Reader",       # 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
    "Cognitive Services Data Reader", # b59867f0-fa02-499b-be73-45a86b5b3e1c
    "Foundry Agent Consumer",         # eed3b665-ab3a-47b6-8f48-c9382fb1dad6
  ]
  description = "Built-in roles granted to the AccuKnox service principal at subscription scope"
}

variable "custom_role_permissions" {
  type = object({
    actions      = list(string)
    data_actions = list(string)
  })
  default = {
    actions = [
      "Microsoft.Resources/subscriptions/read",
      "Microsoft.Resources/subscriptions/resourceGroups/read",
      "Microsoft.Resources/subscriptions/resourceGroups/resources/read",

      "Microsoft.MachineLearningServices/workspaces/read",
      "Microsoft.MachineLearningServices/workspaces/*/read",

      "Microsoft.CognitiveServices/accounts/read",
      "Microsoft.CognitiveServices/accounts/projects/read",
      "Microsoft.CognitiveServices/accounts/deployments/read",

      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/score/action",
      "Microsoft.MachineLearningServices/workspaces/serverlessEndpoints/listKeys/action",

      # classic Foundry / classic Agent Service conversation
      "Microsoft.MachineLearningServices/workspaces/agents/action",

      "Microsoft.MachineLearningServices/workspaces/onlineEndpoints/token/action",
    ]

    data_actions = [
      "Microsoft.CognitiveServices/accounts/OpenAI/deployments/chat/completions/action",
      "Microsoft.CognitiveServices/accounts/OpenAI/deployments/embeddings/action",

      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/read",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/read",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/write",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/messages/read",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/messages/write",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/runs/read",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/runs/write",
      "Microsoft.CognitiveServices/accounts/OpenAI/assistants/threads/runs/steps/read",

      "Microsoft.CognitiveServices/accounts/AIServices/agents/read",
      "Microsoft.CognitiveServices/accounts/AIServices/agents/write",
      "Microsoft.CognitiveServices/accounts/AIServices/endpoints/interact/action",

      "Microsoft.CognitiveServices/accounts/AIServices/evaluations/write",
      "Microsoft.CognitiveServices/accounts/MaaS/chat/completions/action",
      "Microsoft.CognitiveServices/accounts/AIServices/applications/invoke/action",
      "Microsoft.CognitiveServices/accounts/AIServices/responses/read",
      "Microsoft.CognitiveServices/accounts/AIServices/responses/write",
    ]
  }
  description = "Permissions for the AccuKnox custom role used for AI asset inventory and red teaming. actions discover AI resources and call ML endpoints; data_actions send prompts to model deployments and run agent conversations"
}

# ---------------------------------------------------------------------------
# App registration and service principal
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Role assignments
# ---------------------------------------------------------------------------

resource "azurerm_role_assignment" "role" {
  for_each             = toset(var.builtin_roles)
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
    actions      = var.custom_role_permissions.actions
    data_actions = var.custom_role_permissions.data_actions
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

# ---------------------------------------------------------------------------
# Outputs
# ---------------------------------------------------------------------------

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
