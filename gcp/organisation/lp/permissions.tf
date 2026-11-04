locals {
  scan_permissions       = sort(distinct(jsondecode(file("${path.module}/permissions/scan_permissions.json"))))
  scan_permission_chunks = chunklist(local.scan_permissions, 1300)
  scan_custom_role_count = var.scope == "organization" ? length(local.scan_permission_chunks) : 0

  scan_custom_role_entries = {
    for i in range(local.scan_custom_role_count) :
    format("custom_scan_%02d", i + 1) => google_organization_iam_custom_role.scanner_read[i].id
  }

  folder_fallback_role_entries = var.scope == "folder" ? { for r in var.folder_scope_fallback_roles : r => r } : {}
}

resource "google_organization_iam_custom_role" "scanner_read" {
  provider = google-beta
  count    = local.scan_custom_role_count

  org_id      = var.organization_id
  role_id     = format("%s%02d", var.scan_custom_role_id_prefix, count.index + 1)
  title       = "AccuKnox CSPM Scanner Read (${count.index + 1} of ${local.scan_custom_role_count})"
  description = "description"
  permissions = local.scan_permission_chunks[count.index]
}
