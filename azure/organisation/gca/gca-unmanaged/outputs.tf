output "mode" {
  description = "Subscription selection mode in effect."
  value       = var.mode
}

output "lighthouse_definition_id" {
  description = "Resource ID of the shared Lighthouse registration definition."
  value       = azurerm_lighthouse_definition.this.id
}

output "onboarded_subscription_ids" {
  description = "Subscriptions that receive a Lighthouse assignment from this run."
  value       = sort(tolist(local.target_subscription_ids))
}

output "skipped_inactive_subscriptions" {
  description = "Subscriptions selected by the mode rules but skipped because of their state (Disabled / Warned / Deleted)."
  value       = local.skipped_inactive_subscriptions
}

output "effective_exclusions" {
  description = "Exclusions applied to the direct assignments and to the auto-onboarding policy (not_scopes)."
  value = {
    subscription_ids     = sort(tolist(local.excluded_subscription_ids))
    management_group_ids = var.mode == "exclude" ? sort(tolist(local.excluded_management_group_ids)) : []
  }
}

output "auto_onboarding_policy_assignment_ids" {
  description = "Policy assignment IDs keyed by management group (empty when enable_auto_policy = false)."
  value       = { for mg, pa in azurerm_management_group_policy_assignment.auto_onboard : mg => pa.id }
}