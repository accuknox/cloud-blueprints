# Simplified lighthouse outputs
output "lighthouse_definition_id" {
  description = "ID of the shared lighthouse definition."
  value       = azurerm_lighthouse_definition.shared_lighthouse_definition.id
}

output "lighthouse_assignments" {
  description = "Lighthouse assignments created."
  value = {
    include_extra_subscriptions = var.mode == "include" ? [for a in azurerm_lighthouse_assignment.include_extra_subscriptions : a.id] : []
    included_mg_subscriptions   = var.mode == "include" ? [for k, v in azurerm_lighthouse_assignment.included_mg_subscriptions : v.id] : []
    exclude_mode_subscriptions  = var.mode == "exclude" ? [for k, v in azurerm_lighthouse_assignment.exclude_mode_subscriptions : v.id] : []
    exclude_mode_exceptions     = var.mode == "exclude" ? [for a in azurerm_lighthouse_assignment.exclude_mode_exceptions : a.id] : []
  }
}

output "target_subscription_ids" {
  description = "Subscription IDs that will be onboarded based on current mode and configuration."
  value = var.mode == "include" ? concat(
    var.include_extra_subscription_ids,
    local.include_mode_subscription_ids
  ) : concat(
    local.exclude_mode_subscription_ids,
    var.include_exception_subscription_ids
  )
}