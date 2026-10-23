# ==============================================================================
# AccuKnox GCP Organization Onboarding
#
# Grants a read-only auditor service account access to an organization using
# two binding strategies, chosen automatically per scope:
#
#   * INHERITED  — IAM bindings on folders (or the org itself) so that every
#                  current AND FUTURE project underneath is onboarded with no
#                  re-apply ("auto-onboarding" via IAM inheritance).
#   * ENUMERATED — per-project IAM bindings, used wherever an inherited grant
#                  would leak access into an excluded project. Enumerated
#                  scopes pick up new projects on the next `terraform apply`.
#
# A folder is bound INHERITED unless its subtree contains a project from
# exclude_projects (universal exclude), in which case it degrades to
# ENUMERATED so the excluded project is never granted access. See README.
# ==============================================================================

terraform {
  required_version = ">= 1.9.0"
  required_providers {
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

provider "google-beta" {
  project                     = length(var.provider_project_id) > 0 ? var.provider_project_id : null
  impersonate_service_account = length(var.impersonate_service_account) > 0 ? var.impersonate_service_account : null
  billing_project             = length(var.billing_project_id) > 0 ? var.billing_project_id : null
  user_project_override       = true
}

# ==============================================================================
# Discovery — Cloud Asset Inventory at the scope root (org or folder)
# ==============================================================================

data "google_cloud_asset_search_all_resources" "org_projects" {
  provider    = google-beta
  scope       = local.discovery_scope
  asset_types = ["cloudresourcemanager.googleapis.com/Project"]
  query       = "state:ACTIVE"
}

data "google_cloud_asset_search_all_resources" "org_folders" {
  provider    = google-beta
  scope       = local.discovery_scope
  asset_types = ["cloudresourcemanager.googleapis.com/Folder"]
  query       = "state:ACTIVE"
}

locals {
  auditor_member = "serviceAccount:${var.auditor_service_account_email}"

  # ----------------------------------------------------------------------------
  # Scope root: the org node, or a single folder (folder-scoped onboarding for
  # business-unit admins who hold no org-level rights).
  # ----------------------------------------------------------------------------
  root_folder     = var.scope == "folder" ? (startswith(var.root_folder_id, "folders/") ? var.root_folder_id : "folders/${var.root_folder_id}") : ""
  discovery_scope = var.scope == "folder" ? local.root_folder : "organizations/${var.organization_id}"

  # Direct children of the scope root count as "top level" for exclude mode.
  parent_suffix = var.scope == "folder" ? "/${local.root_folder}" : "/organizations/${var.organization_id}"

  # ----------------------------------------------------------------------------
  # Input normalization: accept "123" or "folders/123"
  # ----------------------------------------------------------------------------
  include_folders = [for f in var.include_folders : startswith(f, "folders/") ? f : "folders/${f}"]
  exclude_folders = [for f in var.exclude_folders : startswith(f, "folders/") ? f : "folders/${f}"]

  # ----------------------------------------------------------------------------
  # Asset parsing
  #   project.folders / folder ancestors hold the FULL ancestry chain,
  #   e.g. ["folders/child", "folders/parent"]; null when directly under org.
  # ----------------------------------------------------------------------------
  all_project_assets = [
    for r in data.google_cloud_asset_search_all_resources.org_projects.results : {
      project_id = element(split("/", r.name), length(split("/", r.name)) - 1)
      folders    = r.folders == null ? [] : r.folders
    }
  ]

  all_folder_assets = [
    for r in data.google_cloud_asset_search_all_resources.org_folders.results : {
      folder_id    = "folders/${element(split("/", r.name), length(split("/", r.name)) - 1)}"
      ancestors    = r.folders == null ? [] : r.folders
      is_top_level = endswith(r.parent_full_resource_name == null ? "" : r.parent_full_resource_name, local.parent_suffix)
    }
  ]

  # Folder scope: keep only assets inside the root folder's subtree (also
  # guards against the inventory returning anything broader than the scope).
  project_assets = var.scope == "folder" ? [
    for p in local.all_project_assets : p if contains(p.folders, local.root_folder)
  ] : local.all_project_assets

  folder_assets = var.scope == "folder" ? [
    for fa in local.all_folder_assets : fa
    if fa.folder_id != local.root_folder && contains(fa.ancestors, local.root_folder)
  ] : local.all_folder_assets

  folder_ancestors  = { for fa in local.folder_assets : fa.folder_id => fa.ancestors }
  folder_ids_in_org = [for fa in local.folder_assets : fa.folder_id]

  # Referenced folders that Cloud Asset Inventory does not (yet) know about.
  # They are still bound (a brand-new folder can lag in CAI); a typo fails
  # loudly at apply time. Surfaced in outputs for visibility.
  unmatched_include_folders = [for f in local.include_folders : f if !contains(local.folder_ids_in_org, f)]
  unmatched_exclude_folders = [for f in local.exclude_folders : f if !contains(local.folder_ids_in_org, f)]

  # ============================================================================
  # INCLUDE mode
  # ============================================================================

  # Drop folders nested under another included folder — the ancestor's
  # binding already covers them — and folders that are themselves excluded
  # or sit inside an excluded subtree (exclusions always win).
  include_folders_deduped = [
    for f in local.include_folders : f
    if !anytrue([for g in local.include_folders : g != f && contains(lookup(local.folder_ancestors, f, []), g)])
    && !contains(local.exclude_folders, f)
    && !anytrue([for e in local.exclude_folders : contains(lookup(local.folder_ancestors, f, []), e)])
  ]

  # auto_onboard = false always wins: everything is enumerated, so exclusions
  # are enforced by omission and no deny policies are needed.
  deny_mode = var.exclusion_enforcement == "deny" && var.auto_onboard

  # A folder "degrades" when its subtree contains a universally excluded
  # project or an excluded folder: binding it would leak access into the
  # exclusion. In deny mode nothing degrades (deny policies enforce the
  # exclusions instead); with auto_onboard = false everything degrades so
  # all bindings are per-project.
  include_degraded_folders = local.deny_mode ? [] : (
    !var.auto_onboard ? local.include_folders_deduped : [
      for f in local.include_folders_deduped : f
      if anytrue([
        for p in local.project_assets :
        contains(p.folders, f) && contains(var.exclude_projects, p.project_id)
      ])
      || anytrue([
        for e in local.exclude_folders :
        contains(lookup(local.folder_ancestors, e, []), f)
      ])
    ]
  )

  include_inherited_folders = [
    for f in local.include_folders_deduped : f if !contains(local.include_degraded_folders, f)
  ]

  include_inherited_projects = [
    for p in local.project_assets : p.project_id
    if anytrue([for f in local.include_inherited_folders : contains(p.folders, f)])
  ]

  include_enumerated_projects = distinct(concat(
    [
      for p in local.project_assets : p.project_id
      if anytrue([for f in local.include_degraded_folders : contains(p.folders, f)])
      && !anytrue([for e in local.exclude_folders : contains(p.folders, e)])
      && !contains(var.exclude_projects, p.project_id)
      && !contains(local.include_inherited_projects, p.project_id)
    ],
    [
      for pid in var.include_projects : pid
      if !contains(var.exclude_projects, pid)
      && !contains(local.include_inherited_projects, pid)
      && !anytrue([
        for p in local.project_assets :
        p.project_id == pid && anytrue([for e in local.exclude_folders : contains(p.folders, e)])
      ])
    ],
  ))

  # ============================================================================
  # EXCLUDE mode
  # ============================================================================

  # Bind the scan roles at the ORG node itself — maximum auto-onboarding
  # (future projects AND future folders included) — when auto-onboarding is
  # wanted and either:
  #   * mode is "all" or nothing is excluded, or
  #   * deny mode enforces the exclusions, so the broad allow is safe.
  # mode = "all" shares the exclude-path logic with empty exclusion lists.
  full_org = contains(["all", "exclude"], var.mode) && var.auto_onboard && (
    local.deny_mode || (length(local.exclude_folders) == 0 && length(var.exclude_projects) == 0)
  )

  top_level_folders     = [for fa in local.folder_assets : fa.folder_id if fa.is_top_level]
  candidate_top_folders = [for f in local.top_level_folders : f if !contains(local.exclude_folders, f)]

  # A top-level folder degrades when its subtree contains an excluded
  # (nested) folder or a universally excluded project. Never in deny mode
  # (full_org covers everything and deny policies carve out the exclusions);
  # always with auto_onboard = false (everything is enumerated).
  exclude_degraded_folders = local.deny_mode ? [] : (
    !var.auto_onboard ? local.candidate_top_folders : [
      for f in local.candidate_top_folders : f
      if anytrue(concat(
        [
          for p in local.project_assets :
          contains(p.folders, f) && contains(var.exclude_projects, p.project_id)
        ],
        [
          for ef in local.exclude_folders :
          contains(lookup(local.folder_ancestors, ef, []), f)
        ],
      ))
    ]
  )

  exclude_inherited_folders = local.full_org ? [] : [
    for f in local.candidate_top_folders : f if !contains(local.exclude_degraded_folders, f)
  ]

  # Projects directly under the scope root (the org node, or the root folder).
  org_direct_projects = [
    for p in local.project_assets : p.project_id
    if length([for f in p.folders : f if f != local.root_folder]) == 0
  ]

  exclude_enumerated_projects = local.full_org ? [] : distinct(concat(
    [
      for p in local.project_assets : p.project_id
      if anytrue([for f in local.exclude_degraded_folders : contains(p.folders, f)])
      && !anytrue([for ef in local.exclude_folders : contains(p.folders, ef)])
      && !contains(var.exclude_projects, p.project_id)
    ],
    [
      for pid in local.org_direct_projects : pid
      if !contains(var.exclude_projects, pid)
    ],
  ))

  # ============================================================================
  # Final binding sets
  # ============================================================================

  inherited_folders   = var.mode == "include" ? local.include_inherited_folders : local.exclude_inherited_folders
  enumerated_projects = var.mode == "include" ? local.include_enumerated_projects : local.exclude_enumerated_projects
  degraded_folders    = var.mode == "include" ? local.include_degraded_folders : local.exclude_degraded_folders

  # Custom roles can only be granted within the hierarchy level that owns
  # them: an org custom role needs org-level rights to create, and a project
  # custom role cannot be bound on folders. Folder scope therefore skips the
  # custom role — extend scan_roles instead if those permissions matter.
  custom_role_enabled = var.scope == "organization" && length(var.custom_role_permissions) > 0

  # Scan roles as a map so binding keys stay static while the custom role's
  # fully-qualified name is resolved at apply time.
  scan_role_entries = merge(
    { for r in var.scan_roles : r => r },
    local.custom_role_enabled
    ? { custom_extras = one(google_organization_iam_custom_role.scanner_extras[*].id) }
    : {}
  )

  org_binding_map = var.scope != "organization" ? {} : merge(
    { for r in var.organization_roles : r => r },
    local.full_org ? local.scan_role_entries : {}
  )

  # Folder scope: the metadata roles (and the scan roles when the whole
  # subtree is onboarded) bind on the root folder itself.
  root_folder_binding_map = var.scope != "folder" ? {} : {
    for k, role in merge(
      { for r in var.organization_roles : r => r },
      local.full_org ? local.scan_role_entries : {}
    ) :
    "${local.root_folder}|${k}" => {
      folder = local.root_folder
      role   = role
    }
  }

  folder_binding_map = {
    for pair in setproduct(local.inherited_folders, keys(local.scan_role_entries)) :
    "${pair[0]}|${pair[1]}" => {
      folder = pair[0]
      role   = local.scan_role_entries[pair[1]]
    }
  }

  all_folder_bindings = merge(local.folder_binding_map, local.root_folder_binding_map)

  project_binding_map = {
    for pair in setproduct(local.enumerated_projects, keys(local.scan_role_entries)) :
    "${pair[0]}|${pair[1]}" => {
      project = pair[0]
      role    = local.scan_role_entries[pair[1]]
    }
  }

  # Deny-policy attachment points (deny mode only). Deny policies inherit,
  # so a folder attachment blocks the auditor across the whole subtree.
  deny_attachment_points = !local.deny_mode ? {} : merge(
    {
      for p in var.exclude_projects :
      "projects/${p}" => urlencode("cloudresourcemanager.googleapis.com/projects/${p}")
    },
    {
      for f in local.exclude_folders :
      f => urlencode("cloudresourcemanager.googleapis.com/${f}")
    },
  )

  # Project IDs actually blocked by the deny policies above: excluded projects
  # themselves, plus every project under an excluded folder (deny inherits).
  deny_blocked_project_ids = [
    for p in local.project_assets : p.project_id
    if anytrue([
      for k in keys(local.deny_attachment_points) :
      k == "projects/${p.project_id}" || contains(p.folders, k)
    ])
  ]
}

# ==============================================================================
# Custom role for permissions missing from the built-in scan roles
# ==============================================================================

resource "google_organization_iam_custom_role" "scanner_extras" {
  provider = google-beta
  count    = local.custom_role_enabled ? 1 : 0

  org_id      = var.organization_id
  role_id     = var.custom_role_id
  title       = "AccuKnox CSPM Scanner Extras"
  description = "Read permissions required by AccuKnox CSPM that are not part of the built-in viewer roles."
  permissions = var.custom_role_permissions
}

# ==============================================================================
# IAM bindings
# ==============================================================================

# Organization level: metadata roles always; scan roles too when the whole
# org is onboarded with no exclusions (full auto-onboarding).
resource "google_organization_iam_member" "auditor_org" {
  provider = google-beta
  for_each = local.org_binding_map

  org_id = var.organization_id
  role   = each.value
  member = local.auditor_member
}

# Folder level (INHERITED): new projects under these folders are onboarded
# automatically by IAM inheritance — no re-apply needed. Includes the root
# folder's own bindings in folder scope.
resource "google_folder_iam_member" "auditor_folders" {
  provider = google-beta
  for_each = local.all_folder_bindings

  folder = each.value.folder
  role   = each.value.role
  member = local.auditor_member
}

# Project level (ENUMERATED): scopes where folder inheritance would leak
# access into an excluded project. Re-apply to pick up new projects here.
resource "google_project_iam_member" "auditor_projects" {
  provider = google-beta
  for_each = local.project_binding_map

  project = each.value.project
  role    = each.value.role
  member  = local.auditor_member
}

# Deny mode: IAM Deny policies on excluded projects/folders. Deny is
# evaluated before allow, so these override the inherited org/folder grants
# for the permissions in deny_permissions while everything else
# auto-onboards. This is an OPERATIONAL exclusion: the auditor still holds
# the inherited roles on excluded scopes, and permissions absent from
# deny_permissions (or unsupported by IAM Deny) remain usable there. Hard
# guarantees need exclusion_enforcement = "fallback".
resource "google_iam_deny_policy" "exclusions" {
  provider = google-beta
  for_each = local.deny_attachment_points

  parent       = each.value
  name         = "accuknox-cspm-exclusion"
  display_name = "AccuKnox CSPM exclusion"

  rules {
    deny_rule {
      denied_principals  = ["principal://iam.googleapis.com/projects/-/serviceAccounts/${var.auditor_service_account_email}"]
      denied_permissions = var.deny_permissions
    }
  }
}
