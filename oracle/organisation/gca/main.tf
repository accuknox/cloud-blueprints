terraform {
  required_version = ">= 1.4.0"
  required_providers {
    oci = {
      source  = "oracle/oci"
      version = ">= 5.0.0"
    }
  }
}

provider "oci" {
  # Configure authentication via ~/.oci/config or environment variables
  # config_file_profile = "DEFAULT"
}

locals {
  cross_tenancy_enabled      = var.cross_tenancy_enabled
  policy_compartment_id      = length(trimspace(var.policy_compartment_ocid)) > 0 ? var.policy_compartment_ocid : var.tenancy_ocid
  principal_tenancy_alias    = trimspace(var.principal_tenancy_alias)
  principal_tenancy_ocid     = trimspace(var.principal_tenancy_ocid)
  # Extract group name without identity domain prefix for define statements
  principal_name_without_domain = length(split("/", var.principal_name)) > 1 ? element(split("/", var.principal_name), 1) : var.principal_name
  principal_statement_prefix = local.cross_tenancy_enabled ? format("admit %s %s of tenancy %s to", var.principal_type, var.principal_name, local.principal_tenancy_alias) : format("allow %s %s to", var.principal_type, var.principal_name)
}

# Fetch tenancy metadata for root-compartment naming.
data "oci_identity_tenancy" "this" {
  tenancy_id = var.tenancy_ocid
}

# Discover all compartments under the tenancy.
data "oci_identity_compartments" "all" {
  compartment_id            = var.tenancy_ocid
  access_level              = "ANY"
  compartment_id_in_subtree = true
}

# Note: subtrees are discovered using parent-child relationships in locals
# OCI API doesn't support compartmentIdInSubtree=true for non-tenancy compartments

locals {
  root_compartment = {
    id        = var.tenancy_ocid
    name      = data.oci_identity_tenancy.this.name
    parent_id = null
    path      = data.oci_identity_tenancy.this.name
  }

  discovered_compartments = [
    for compartment in data.oci_identity_compartments.all.compartments : {
      id          = compartment.id
      name        = compartment.name
      parent_id   = compartment.compartment_id
      path        = try(compartment.path, null)
      description = compartment.description
    }
  ]

  compartment_map = {
    for item in concat([local.root_compartment], local.discovered_compartments) :
    item.id => item
  }

  all_compartment_ids = keys(local.compartment_map)

  # Build descendants map top-down starting from root
  # OCI supports maximum 6 levels of compartment nesting

  # Level 1: Direct children of each compartment
  children_level_1 = {
    for parent_id in local.all_compartment_ids :
    parent_id => [
      for id, item in local.compartment_map :
      id if item.parent_id == parent_id
    ]
  }

  # Level 2: Children of level 1 children
  children_level_2 = {
    for parent_id in local.all_compartment_ids :
    parent_id => flatten([
      for child_id in local.children_level_1[parent_id] :
      local.children_level_1[child_id]
    ])
  }

  # Level 3: Children of level 2 children
  children_level_3 = {
    for parent_id in local.all_compartment_ids :
    parent_id => flatten([
      for child_id in local.children_level_2[parent_id] :
      local.children_level_1[child_id]
    ])
  }

  # Level 4: Children of level 3 children
  children_level_4 = {
    for parent_id in local.all_compartment_ids :
    parent_id => flatten([
      for child_id in local.children_level_3[parent_id] :
      local.children_level_1[child_id]
    ])
  }

  # Level 5: Children of level 4 children
  children_level_5 = {
    for parent_id in local.all_compartment_ids :
    parent_id => flatten([
      for child_id in local.children_level_4[parent_id] :
      local.children_level_1[child_id]
    ])
  }

  # Level 6: Children of level 5 children
  children_level_6 = {
    for parent_id in local.all_compartment_ids :
    parent_id => flatten([
      for child_id in local.children_level_5[parent_id] :
      local.children_level_1[child_id]
    ])
  }

  # Combine all levels to get complete descendant tree
  descendants_map = {
    for parent_id in local.all_compartment_ids :
    parent_id => distinct(concat(
      local.children_level_1[parent_id],
      local.children_level_2[parent_id],
      local.children_level_3[parent_id],
      local.children_level_4[parent_id],
      local.children_level_5[parent_id],
      local.children_level_6[parent_id]
    ))
  }

  include_subtree_ids = flatten([
    for ocid in var.included_compartment_ocids :
    ocid == var.tenancy_ocid ? local.all_compartment_ids :
    concat([ocid], lookup(local.descendants_map, ocid, []))
  ])

  include_mode_candidates = distinct(concat(
    local.include_subtree_ids,
    var.included_leaf_compartment_ocids
  ))

  include_mode_final_ids = [
    for ocid in local.include_mode_candidates :
    ocid if !contains(var.include_excluded_compartment_ocids, ocid)
  ]

  # Build WHERE clause exclusions for INCLUDE mode
  # Map each included compartment to descendants that should be excluded
  include_mode_exclusion_map = {
    for ocid in local.include_mode_final_ids :
    ocid => [
      for excluded_ocid in var.include_excluded_compartment_ocids :
      excluded_ocid if contains(lookup(local.descendants_map, ocid, []), excluded_ocid)
    ]
  }

  # Build WHERE clause exclusions for ALL mode
  # Map each compartment to descendants that should be excluded
  all_mode_exclusion_map = {
    for ocid in local.all_mode_final_ids :
    ocid => [
      for excluded_ocid in var.all_excluded_compartment_ocids :
      excluded_ocid if contains(lookup(local.descendants_map, ocid, []), excluded_ocid)
    ]
  }

  exclude_subtree_ids = flatten([
    for ocid in var.excluded_compartment_ocids :
    ocid == var.tenancy_ocid ? local.all_compartment_ids :
    concat([ocid], lookup(local.descendants_map, ocid, []))
  ])

  exclude_mode_removed_ids = distinct(concat(
    local.exclude_subtree_ids,
    var.exclude_additional_compartment_ocids
  ))

  exclude_mode_candidates = [
    for ocid in local.all_compartment_ids :
    ocid if !contains(local.exclude_mode_removed_ids, ocid)
  ]

  # Build exception subtree IDs (includes descendants of exception compartments)
  exception_subtree_ids = flatten([
    for ocid in var.exception_compartment_ocids :
    ocid == var.tenancy_ocid ? local.all_compartment_ids :
    concat([ocid], lookup(local.descendants_map, ocid, []))
  ])

  exclude_mode_final_ids = distinct([
    for ocid in concat(local.exclude_mode_candidates, local.exception_subtree_ids) :
    ocid if (
      # Exclude tenancy root when there are exclusions (to avoid tenancy-level grants)
      length(var.excluded_compartment_ocids) == 0 && length(var.exclude_additional_compartment_ocids) == 0 || ocid != var.tenancy_ocid
    )
  ])

  all_mode_final_ids = [
    for ocid in local.all_compartment_ids :
    ocid if !contains(var.all_excluded_compartment_ocids, ocid) && (
      # Exclude tenancy root when there are exclusions (to avoid tenancy-level grants)
      length(var.all_excluded_compartment_ocids) == 0 || ocid != var.tenancy_ocid
    )
  ]

  base_final_compartment_ids = (
    var.mode == "all" ? local.all_mode_final_ids :
    var.mode == "include" ? local.include_mode_final_ids :
    var.mode == "exclude" ? local.exclude_mode_final_ids :
    []
  )

  final_compartment_ids = distinct(concat(
    local.base_final_compartment_ids,
    var.extra_compartment_ocids
  ))

  unknown_compartment_ocids = [
    for ocid in local.final_compartment_ids :
    ocid if !contains(local.all_compartment_ids, ocid)
  ]

  final_compartments = [
    for ocid in local.final_compartment_ids :
    merge(local.compartment_map[ocid], { is_tenancy = ocid == var.tenancy_ocid })
    if contains(local.all_compartment_ids, ocid)
  ]

  # Helper to build WHERE clause for compartment exclusions
  compartment_exclusion_where_clauses = var.mode == "include" ? {
    for ocid in local.include_mode_final_ids :
    ocid => length(lookup(local.include_mode_exclusion_map, ocid, [])) > 0 ? join(" AND ", [
      for excluded_ocid in lookup(local.include_mode_exclusion_map, ocid, []) :
      format("target.compartment.id != '%s'", excluded_ocid)
    ]) : ""
  } : var.mode == "all" && length(var.all_excluded_compartment_ocids) > 0 ? {
    for ocid in local.all_mode_final_ids :
    ocid => length(lookup(local.all_mode_exclusion_map, ocid, [])) > 0 ? join(" AND ", [
      for excluded_ocid in lookup(local.all_mode_exclusion_map, ocid, []) :
      format("target.compartment.id != '%s'", excluded_ocid)
    ]) : ""
  } : {}

  # Pre-compute combined WHERE clauses for each compartment + permission combination
  compartment_permission_where_clauses = {
    for key, compartment in { for idx, comp in local.final_compartments : idx => comp } :
    compartment.id => {
      for permission in var.policy_permissions :
      "${permission.action}-${permission.resource}" => join(" AND ", compact([
        trimspace(permission.where_clause),
        lookup(local.compartment_exclusion_where_clauses, compartment.id, "")
      ]))
    }
  }

  base_policy_statements = var.mode == "all" && length(var.all_excluded_compartment_ocids) == 0 ? [
    # For ALL mode with NO exclusions, generate tenancy-level statements (covers all compartments)
    for permission in var.policy_permissions :
    format(
      "%s %s %s in tenancy%s",
      local.principal_statement_prefix,
      permission.action,
      permission.resource,
      length(trimspace(permission.where_clause)) > 0 ? format(" where %s", permission.where_clause) : ""
    )
  ] : flatten([
    # For ALL mode WITH exclusions, INCLUDE mode, or EXCLUDE mode, generate per-compartment statements
    for compartment in local.final_compartments : [
      for permission in var.policy_permissions :
      compartment.is_tenancy ?
      format(
        "%s %s %s in tenancy%s",
        local.principal_statement_prefix,
        permission.action,
        permission.resource,
        length(trimspace(permission.where_clause)) > 0 ? format(" where %s", permission.where_clause) : ""
      )
      :
      (
        length(lookup(lookup(local.compartment_permission_where_clauses, compartment.id, {}), "${permission.action}-${permission.resource}", "")) > 0 ?
        format(
          "%s %s %s in compartment id %s where %s",
          local.principal_statement_prefix,
          permission.action,
          permission.resource,
          compartment.id,
          lookup(lookup(local.compartment_permission_where_clauses, compartment.id, {}), "${permission.action}-${permission.resource}", "")
        )
        :
        format(
          "%s %s %s in compartment id %s",
          local.principal_statement_prefix,
          permission.action,
          permission.resource,
          compartment.id
        )
      )
    ]
  ])

  cross_tenancy_define_statements = local.cross_tenancy_enabled ? concat(
    [format("define tenancy %s as %s", local.principal_tenancy_alias, local.principal_tenancy_ocid)],
    var.principal_type == "group" && length(trimspace(var.principal_group_ocid)) > 0 ?
      [format("define group %s as %s", local.principal_name_without_domain, var.principal_group_ocid)] : []
  ) : []

  cross_tenancy_endorse_statements = local.cross_tenancy_enabled ? [
    format("endorse %s %s to use tenancy %s", var.principal_type, var.principal_name, local.principal_tenancy_alias)
  ] : []

  generated_policy_statements = distinct(concat(
    local.cross_tenancy_define_statements,
    local.base_policy_statements,
    var.additional_policy_statements
  ))

  debug_compartment_map = var.mode_debug ? local.compartment_map : {}
}

resource "oci_identity_policy" "principal_access" {
  compartment_id = local.policy_compartment_id
  name           = var.policy_name
  description    = var.policy_description
  statements     = local.generated_policy_statements

  lifecycle {
    precondition {
      condition     = length(local.generated_policy_statements) > 0
      error_message = "No policy statements were generated. Verify that your mode inputs produce at least one compartment."
    }

    precondition {
      condition     = length(local.unknown_compartment_ocids) == 0
      error_message = format("The following compartment OCIDs could not be resolved: %s", join(", ", local.unknown_compartment_ocids))
    }
  }
}
