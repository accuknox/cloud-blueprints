terraform {
  required_version = ">= 1.4.0"
  required_providers {
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0"
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
# Data Sources for Project Discovery
# ==============================================================================

# Discover all projects directly under the organization
data "google_projects" "org_projects" {
  provider = google-beta
  filter   = "parent.id:${var.organization_id} parent.type:organization lifecycleState:ACTIVE"
}

# Discover ALL projects in the organization (including those in folders) using Cloud Asset Inventory
# This is used for ALL mode and EXCLUDE mode to recursively discover all projects
data "google_cloud_asset_search_all_resources" "all_org_projects" {
  provider = google-beta
  scope    = "organizations/${var.organization_id}"
  asset_types = [
    "cloudresourcemanager.googleapis.com/Project"
  ]
  query = "state:ACTIVE"
}

# ==============================================================================
# Locals for Project Discovery Logic
# ==============================================================================

locals {
  auditor_member = "serviceAccount:${var.auditor_service_account_email}"

  # Organization-level roles
  # NOTE: roles/cloudasset.viewer is intentionally excluded because it grants
  # access to resources across ALL projects via searchAllResources API.
  # AccuKnox should only access resources in onboarded projects via project-level roles.
  # roles/browser allows listing projects/folders (metadata only) without resource access.
  default_organization_roles = [
    "roles/browser",
    "roles/logging.viewer",
    "roles/iam.securityReviewer",
    "roles/securitycenter.viewer",
    "roles/orgpolicy.policyViewer",
  ]

  organization_roles = distinct(concat(local.default_organization_roles, var.additional_organization_roles))

  # All projects directly under organization
  org_level_projects = [for project in data.google_projects.org_projects.projects : project.project_id]

  # Normalize folder identifiers (allow plain numeric IDs)
  normalized_included_folder_ids = [
    for folder_id in var.included_folder_ids :
    startswith(folder_id, "folders/") ? folder_id : "folders/${folder_id}"
  ]

  normalized_excluded_folder_ids = [
    for folder_id in var.excluded_folder_ids :
    startswith(folder_id, "folders/") ? folder_id : "folders/${folder_id}"
  ]

  # Cloud Asset Inventory results for every project (includes ancestor folders)
  project_assets = [
    for result in data.google_cloud_asset_search_all_resources.all_org_projects.results : {
      project_id = element(split("/", result.name), length(split("/", result.name)) - 1)
      folders = distinct(concat(
        try(result.folders, []),
        [
          for ancestor in try(result.ancestors, []) :
          ancestor if startswith(ancestor, "folders/")
        ]
      ))
    }
  ]

  all_org_projects = [for asset in local.project_assets : asset.project_id]

  included_assets = [
    for asset in local.project_assets :
    asset if length([
      for folder in asset.folders :
      folder if contains(local.normalized_included_folder_ids, folder)
    ]) > 0
  ]

  excluded_assets = [
    for asset in local.project_assets :
    asset if length([
      for folder in asset.folders :
      folder if contains(local.normalized_excluded_folder_ids, folder)
    ]) > 0
  ]

  # ==============================================================================
  # INCLUDE Mode Logic
  # ==============================================================================

  included_folder_project_ids = [for asset in local.included_assets : asset.project_id]

  include_mode_projects = distinct(concat(
    local.included_folder_project_ids,
    var.included_project_ids
  ))

  include_mode_final = [
    for project_id in local.include_mode_projects :
    project_id if !contains(var.include_excluded_project_ids, project_id)
  ]

  included_nested_folder_ids = distinct(flatten([
    for asset in local.included_assets : [
      for folder in asset.folders :
      folder if !contains(local.normalized_included_folder_ids, folder)
    ]
  ]))

  # ==============================================================================
  # EXCLUDE Mode Logic
  # ==============================================================================

  excluded_folder_project_ids = [for asset in local.excluded_assets : asset.project_id]

  all_excluded_project_ids = distinct(concat(
    local.excluded_folder_project_ids,
    var.exclude_excluded_project_ids
  ))

  exclude_mode_projects = [
    for project_id in local.all_org_projects :
    project_id if !contains(local.all_excluded_project_ids, project_id)
  ]

  exclude_mode_final = distinct(concat(
    local.exclude_mode_projects,
    var.exception_project_ids
  ))

  excluded_nested_folder_ids = distinct(flatten([
    for asset in local.excluded_assets : [
      for folder in asset.folders :
      folder if !contains(local.normalized_excluded_folder_ids, folder)
    ]
  ]))

  # ==============================================================================
  # ALL Mode Logic
  # ==============================================================================

  all_mode_final = [
    for project_id in local.all_org_projects :
    project_id if !contains(var.all_excluded_project_ids, project_id)
  ]

  # ==============================================================================
  # Final Project List Based on Mode
  # ==============================================================================

  final_project_ids = (
    var.mode == "all" ? local.all_mode_final :
    var.mode == "include" ? local.include_mode_final :
    var.mode == "exclude" ? local.exclude_mode_final :
    []
  )

  # Backward compatibility: Combine with deprecated project_ids variable
  all_project_ids = distinct(concat(local.final_project_ids, var.project_ids))

  # ==============================================================================
  # IAM Binding Maps
  # ==============================================================================

  # Folder bindings (optional custom folder roles)
  folder_role_pairs = flatten([
    for binding in var.folder_bindings : [
      for role in binding.roles : {
        folder_id = binding.folder_id
        role      = role
      }
    ]
  ])

  folder_binding_map = {
    for pair in local.folder_role_pairs :
    "${pair.folder_id}/${pair.role}" => {
      folder = startswith(pair.folder_id, "folders/") ? pair.folder_id : "folders/${pair.folder_id}"
      role   = pair.role
    }
  }

  # Project role pairs for default roles
  project_role_pairs = flatten([
    for project_id in local.all_project_ids : [
      for role in var.project_roles : {
        project_id = project_id
        role       = role
      }
    ]
  ])

  # Final project binding map
  project_binding_map = {
    for pair in local.project_role_pairs :
    "${pair.project_id}/${pair.role}" => pair
  }
}

# ==============================================================================
# IAM Resources
# ==============================================================================

# Grant organization-level roles
resource "google_organization_iam_member" "auditor_org_roles" {
  provider = google-beta
  for_each = toset(local.organization_roles)

  org_id = var.organization_id
  role   = each.key
  member = local.auditor_member
}

# Grant folder-level roles (optional)
resource "google_folder_iam_member" "auditor_folder_roles" {
  provider = google-beta
  for_each = local.folder_binding_map

  folder = each.value.folder
  role   = each.value.role
  member = local.auditor_member
}

# Grant project-level roles
resource "google_project_iam_member" "auditor_project_roles" {
  provider = google-beta
  for_each = local.project_binding_map

  project = each.value.project_id
  role    = each.value.role
  member  = local.auditor_member
}
