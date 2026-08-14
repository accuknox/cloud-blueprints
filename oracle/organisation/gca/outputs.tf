output "final_compartment_ocids" {
  description = "Ordered list of compartment OCIDs that received policy bindings based on the selected mode."
  value       = [for compartment in local.final_compartments : compartment.id]
}

output "final_compartment_names" {
  description = "Ordered list of compartment names aligned with final_compartment_ocids."
  value       = [for compartment in local.final_compartments : compartment.name]
}

output "final_compartment_count" {
  description = "Total number of compartments onboarded."
  value       = length(local.final_compartments)
}

output "generated_policy_statements" {
  description = "The complete set of policy statements applied by this module."
  value       = local.generated_policy_statements
}

output "cross_tenancy_define_statements" {
  description = "Define statements created in the resource tenancy when cross-tenancy is enabled."
  value       = local.cross_tenancy_define_statements
}

output "cross_tenancy_endorse_statements" {
  description = "Endorse statements that the remote tenancy must apply when cross-tenancy is enabled."
  value       = local.cross_tenancy_endorse_statements
}

output "mode_details" {
  description = "Details about the onboarding mode configuration."
  value = {
    mode = var.mode

    all_mode = var.mode == "all" ? {
      excluded_compartments = var.all_excluded_compartment_ocids
    } : null

    include_mode = var.mode == "include" ? {
      included_compartments      = var.included_compartment_ocids
      included_leaf_compartments = var.included_leaf_compartment_ocids
      excluded_compartments      = var.include_excluded_compartment_ocids
    } : null

    exclude_mode = var.mode == "exclude" ? {
      excluded_compartments           = var.excluded_compartment_ocids
      exclude_additional_compartments = var.exclude_additional_compartment_ocids
      exception_compartments          = var.exception_compartment_ocids
    } : null
  }
}

output "compartment_debug_map" {
  description = "Raw compartment discovery map. Enabled only when mode_debug is set to true."
  value       = local.debug_compartment_map
  sensitive   = true
}
