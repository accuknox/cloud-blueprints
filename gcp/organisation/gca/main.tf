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

  root_folder     = var.scope == "folder" ? (startswith(var.root_folder_id, "folders/") ? var.root_folder_id : "folders/${var.root_folder_id}") : ""
  discovery_scope = var.scope == "folder" ? local.root_folder : "organizations/${var.organization_id}"

  parent_suffix = var.scope == "folder" ? "/${local.root_folder}" : "/organizations/${var.organization_id}"

  include_folders = [for f in var.include_folders : startswith(f, "folders/") ? f : "folders/${f}"]
  exclude_folders = [for f in var.exclude_folders : startswith(f, "folders/") ? f : "folders/${f}"]

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

  project_assets = var.scope == "folder" ? [
    for p in local.all_project_assets : p if contains(p.folders, local.root_folder)
  ] : local.all_project_assets

  folder_assets = var.scope == "folder" ? [
    for fa in local.all_folder_assets : fa
    if fa.folder_id != local.root_folder && contains(fa.ancestors, local.root_folder)
  ] : local.all_folder_assets

  folder_ancestors  = { for fa in local.folder_assets : fa.folder_id => fa.ancestors }
  folder_ids_in_org = [for fa in local.folder_assets : fa.folder_id]

  unmatched_include_folders = [for f in local.include_folders : f if !contains(local.folder_ids_in_org, f)]
  unmatched_exclude_folders = [for f in local.exclude_folders : f if !contains(local.folder_ids_in_org, f)]

  include_folders_deduped = [
    for f in local.include_folders : f
    if !anytrue([for g in local.include_folders : g != f && contains(lookup(local.folder_ancestors, f, []), g)])
    && !contains(local.exclude_folders, f)
    && !anytrue([for e in local.exclude_folders : contains(lookup(local.folder_ancestors, f, []), e)])
  ]

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

  full_org = contains(["all", "exclude"], var.mode) && var.auto_onboard && (
    local.deny_mode || (length(local.exclude_folders) == 0 && length(var.exclude_projects) == 0)
  )

  top_level_folders     = [for fa in local.folder_assets : fa.folder_id if fa.is_top_level]
  candidate_top_folders = [for f in local.top_level_folders : f if !contains(local.exclude_folders, f)]

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

  inherited_folders   = var.mode == "include" ? local.include_inherited_folders : local.exclude_inherited_folders
  enumerated_projects = var.mode == "include" ? local.include_enumerated_projects : local.exclude_enumerated_projects
  degraded_folders    = var.mode == "include" ? local.include_degraded_folders : local.exclude_degraded_folders

  custom_role_enabled = var.scope == "organization" && length(var.custom_role_permissions) > 0

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

  deny_blocked_project_ids = [
    for p in local.project_assets : p.project_id
    if anytrue([
      for k in keys(local.deny_attachment_points) :
      k == "projects/${p.project_id}" || contains(p.folders, k)
    ])
  ]
}


resource "google_organization_iam_custom_role" "scanner_extras" {
  provider = google-beta
  count    = local.custom_role_enabled ? 1 : 0

  org_id      = var.organization_id
  role_id     = var.custom_role_id
  title       = "AccuKnox CSPM Scanner Extras"
  description = "Read permissions required by AccuKnox CSPM that are not part of the built-in viewer roles."
  permissions = var.custom_role_permissions
}

resource "google_organization_iam_member" "auditor_org" {
  provider = google-beta
  for_each = local.org_binding_map

  org_id = var.organization_id
  role   = each.value
  member = local.auditor_member
}

resource "google_folder_iam_member" "auditor_folders" {
  provider = google-beta
  for_each = local.all_folder_bindings

  folder = each.value.folder
  role   = each.value.role
  member = local.auditor_member
}

resource "google_project_iam_member" "auditor_projects" {
  provider = google-beta
  for_each = local.project_binding_map

  project = each.value.project
  role    = each.value.role
  member  = local.auditor_member
}

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
