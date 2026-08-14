output "mode" {
  description = "Onboarding mode used (all, include, or exclude)."
  value       = var.mode
}

output "auditor_member" {
  description = "IAM member string constructed for the auditing service account."
  value       = local.auditor_member
}

output "organization_roles_granted" {
  description = "Organization-level roles granted to the auditing service account."
  value       = tolist(toset(local.organization_roles))
}

output "projects_onboarded" {
  description = "List of project IDs that have been onboarded."
  value       = local.final_project_ids
}

output "projects_onboarded_count" {
  description = "Total number of projects onboarded."
  value       = length(local.final_project_ids)
}

output "project_role_bindings" {
  description = "Project and role combinations granted to the auditing service account."
  value = [
    for _, binding in local.project_binding_map : {
      project_id = binding.project_id
      role       = binding.role
    }
  ]
}

output "folder_role_bindings" {
  description = "Folder-level role bindings applied to the auditing service account."
  value = [
    for _, binding in local.folder_binding_map : {
      folder = binding.folder
      role   = binding.role
    }
  ]
}

# Mode-specific outputs
output "mode_details" {
  description = "Details about the onboarding mode configuration."
  value = {
    mode = var.mode

    all_mode = var.mode == "all" ? {
      excluded_projects = var.all_excluded_project_ids
    } : null

    include_mode = var.mode == "include" ? {
      included_folders          = var.included_folder_ids
      included_projects         = var.included_project_ids
      excluded_projects         = var.include_excluded_project_ids
      discovered_nested_folders = local.included_nested_folder_ids
    } : null

    exclude_mode = var.mode == "exclude" ? {
      excluded_folders          = var.excluded_folder_ids
      excluded_projects         = var.exclude_excluded_project_ids
      exception_projects        = var.exception_project_ids
      discovered_nested_folders = local.excluded_nested_folder_ids
    } : null
  }
}

