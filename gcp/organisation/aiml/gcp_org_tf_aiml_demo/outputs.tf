output "mode" {
  description = "Onboarding mode used ('include' or 'exclude')."
  value       = var.mode
}

output "auditor_member" {
  description = "IAM member string granted access."
  value       = local.auditor_member
}

output "full_org_inherited" {
  description = "True when the scan roles are bound at the scope root itself (org node, or the root folder in folder scope): every current and future project in scope is onboarded automatically."
  value       = local.full_org
}

output "scope_root" {
  description = "The node this onboarding is rooted at."
  value       = local.discovery_scope
}

output "root_folder_roles_granted" {
  description = "Roles bound on the root folder (folder scope only): the metadata roles, plus the scan roles when the whole subtree is inherited."
  value       = sort([for k, v in local.root_folder_binding_map : split("|", k)[1]])
}

output "organization_roles_granted" {
  description = "Organization-level bindings (metadata roles, plus the scan roles when full_org_inherited is true)."
  value       = sort(keys(local.org_binding_map))
}

output "inherited_folder_bindings" {
  description = "Folders bound at folder level. New projects created anywhere under these folders (including nested folders) are onboarded AUTOMATICALLY via IAM inheritance."
  value       = local.inherited_folders
}

output "enumerated_projects" {
  description = "Projects bound individually. New projects in these scopes are picked up on the next terraform apply (schedule a periodic apply if needed)."
  value       = local.enumerated_projects
}

output "degraded_folders" {
  description = "Folders that fell back from folder-level to per-project bindings because their subtree contains a project from exclude_projects. Auto-onboarding is NOT active for these folders; re-apply to pick up new projects."
  value       = local.degraded_folders
}

output "projects_currently_inherited" {
  description = "Projects currently covered via folder/org inheritance (informational snapshot; future projects in those scopes are added automatically without appearing here until the next refresh)."
  value = local.full_org ? [for p in local.project_assets : p.project_id] : [
    for p in local.project_assets : p.project_id
    if anytrue([for f in local.inherited_folders : contains(p.folders, f)])
  ]
}

output "excluded_projects_applied" {
  description = "Projects from exclude_projects that were found in the organization and skipped."
  value       = [for p in local.project_assets : p.project_id if contains(var.exclude_projects, p.project_id)]
}

output "unmatched_include_folders" {
  description = "Included folders not (yet) visible in Cloud Asset Inventory. They are still bound (new folders can lag in CAI); a typo will fail at apply."
  value       = local.unmatched_include_folders
}

output "unmatched_exclude_folders" {
  description = "Excluded folders not (yet) visible in Cloud Asset Inventory. Verify these IDs: an unmatched exclusion excludes nothing."
  value       = local.unmatched_exclude_folders
}

output "auto_onboard_summary" {
  description = "Where new projects are onboarded automatically vs. where a re-apply is required."
  value = {
    automatic = !var.auto_onboard ? [] : (local.full_org ? [
      var.scope == "folder" ? "entire folder subtree (root-folder binding)" : "entire organization (org-level binding)"
      ] : [
      for f in local.inherited_folders : "${f} (folder-level binding)"
    ])
    requires_reapply = !var.auto_onboard ? ["all onboarded scopes (auto_onboard = false — new projects are added only on terraform apply)"] : concat(
      [for f in local.degraded_folders : "${f} (contains exclusions)"],
      var.mode != "include" && !local.full_org ? ["projects created directly under the ${var.scope == "folder" ? "root folder" : "organization"}", "new top-level folders"] : [],
      var.mode == "include" && length(var.include_projects) > 0 ? ["individually included projects (include_projects)"] : [],
    )
  }
}

output "deny_policies_attached" {
  description = "Scopes carrying an IAM Deny policy against the auditor (exclusion_enforcement = 'deny' only). Deny inherits, so folder entries block their whole subtree."
  value       = sort(keys(local.deny_attachment_points))
}

output "projects_with_access" {
  description = "Effective list of projects the auditor SA can actually read: every project covered by inheritance or an individual binding, minus any blocked by a deny policy. This is the definitive 'who got access' list."
  value = sort(distinct([
    for pid in concat(
      local.full_org ? [for p in local.project_assets : p.project_id] : [
        for p in local.project_assets : p.project_id
        if anytrue([for f in local.inherited_folders : contains(p.folders, f)])
      ],
      local.enumerated_projects,
    ) : pid
    if !contains(local.deny_blocked_project_ids, pid)
  ]))
}

output "projects_with_access_count" {
  description = "Total number of projects the auditor SA can read (length of projects_with_access)."
  value = length(distinct([
    for pid in concat(
      local.full_org ? [for p in local.project_assets : p.project_id] : [
        for p in local.project_assets : p.project_id
        if anytrue([for f in local.inherited_folders : contains(p.folders, f)])
      ],
      local.enumerated_projects,
    ) : pid
    if !contains(local.deny_blocked_project_ids, pid)
  ]))
}

output "binding_counts" {
  description = "Number of IAM member bindings managed at each level."
  value = {
    organization = length(local.org_binding_map)
    folder       = length(local.all_folder_bindings)
    project      = length(local.project_binding_map)
  }
}
