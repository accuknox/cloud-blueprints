# ==============================================================================
# Core inputs
# ==============================================================================

variable "mode" {
  description = "Onboarding mode: 'all' (onboard the entire organization, no scoping lists), 'include' (onboard only listed folders/projects), or 'exclude' (onboard everything except listed folders/projects). With mode = 'all': auto_onboard = true binds the scan roles once at the org node so every new project/folder is onboarded instantly; auto_onboard = false enumerates every project individually."
  type        = string

  validation {
    condition     = contains(["all", "include", "exclude"], var.mode)
    error_message = "Mode must be 'all', 'include' or 'exclude'."
  }

  validation {
    condition     = var.mode != "include" || length(var.include_folders) > 0 || length(var.include_projects) > 0
    error_message = "In 'include' mode, set at least one of include_folders or include_projects."
  }

  validation {
    condition     = var.mode == "include" || (length(var.include_folders) == 0 && length(var.include_projects) == 0)
    error_message = "include_folders / include_projects are only used when mode = 'include'."
  }

  validation {
    condition     = var.mode != "all" || (length(var.exclude_folders) == 0 && length(var.exclude_projects) == 0)
    error_message = "mode = 'all' takes no scoping lists — use mode = 'exclude' if you need exclusions."
  }

}

variable "scope" {
  description = "Onboarding scope root: 'organization' (default — needs org-level deployer rights) or 'folder' (onboard a single folder subtree; runnable by a folder admin with no org-level rights — set root_folder_id). In folder scope the metadata roles bind on the root folder, discovery is folder-scoped, and the org custom role is skipped."
  type        = string
  default     = "organization"

  validation {
    condition     = contains(["organization", "folder"], var.scope)
    error_message = "scope must be 'organization' or 'folder'."
  }

  validation {
    condition     = var.scope == "folder" ? length(var.root_folder_id) > 0 : length(var.organization_id) > 0
    error_message = "Set organization_id for scope = 'organization', or root_folder_id for scope = 'folder'."
  }

  validation {
    condition     = var.scope == "folder" || length(var.root_folder_id) == 0
    error_message = "root_folder_id is only used when scope = 'folder'."
  }
}

variable "organization_id" {
  description = "Numeric ID of the Google Cloud organization to onboard. Required when scope = 'organization'."
  type        = string
  default     = ""

  validation {
    condition     = var.organization_id == "" || can(regex("^[0-9]+$", var.organization_id))
    error_message = "organization_id must be the numeric organization ID (e.g. 955809990560)."
  }
}

variable "root_folder_id" {
  description = "Folder that is the onboarding root when scope = 'folder'. Accepts '123456789' or 'folders/123456789'. Everything underneath (nested folders included) is in scope; nothing outside it is touched."
  type        = string
  default     = ""

  validation {
    condition     = var.root_folder_id == "" || can(regex("^(folders/)?[0-9]+$", var.root_folder_id))
    error_message = "root_folder_id must be a numeric folder ID, optionally prefixed with 'folders/'."
  }
}

variable "auditor_service_account_email" {
  description = "Email of the auditing service account that receives the read-only roles."
  type        = string
  default     = "accuknox-organisation-scanner@accuknox-gcp.iam.gserviceaccount.com"

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.iam\\.gserviceaccount\\.com$", var.auditor_service_account_email))
    error_message = "auditor_service_account_email must be a service account email (example: sa@project.iam.gserviceaccount.com)."
  }
}

# ==============================================================================
# Scoping — INCLUDE mode
# ==============================================================================

variable "include_folders" {
  description = "INCLUDE mode: folders to onboard. Accepts '123456789' or 'folders/123456789'. Each folder receives folder-level IAM bindings, so every current AND FUTURE project underneath (including nested folders) is onboarded automatically — unless the folder's subtree contains a project listed in exclude_projects, in which case that folder falls back to per-project bindings (see README)."
  type        = list(string)
  default     = []
}

variable "include_projects" {
  description = "INCLUDE mode: extra individual projects to onboard that live OUTSIDE the included folders (e.g. directly under the organization or in folders you did not include). Always bound per-project."
  type        = list(string)
  default     = []
}

# ==============================================================================
# Scoping — universal excludes (both modes)
# ==============================================================================

variable "exclude_folders" {
  description = "UNIVERSAL folder exclude (works in BOTH modes): folder subtrees to skip entirely — in exclude mode anywhere in the org, in include mode even when nested inside an included folder (exclusions always win over inclusions). Accepts '123456789' or 'folders/123456789'."
  type        = list(string)
  default     = []
}

variable "exclude_projects" {
  description = "UNIVERSAL exclude list (works in BOTH modes): individual project IDs to skip, even if their parent folder is being onboarded. How the skip is enforced depends on exclusion_enforcement."
  type        = list(string)
  default     = []
}

variable "auto_onboard" {
  description = "true (default): bind at folder/org level wherever possible so new projects are onboarded automatically via IAM inheritance. false: force per-project bindings everywhere — new projects are onboarded ONLY on the next terraform apply, giving the customer explicit control over every addition. Overrides exclusion_enforcement: with auto_onboard = false, exclusions are enforced by enumeration and no deny policies are created."
  type        = bool
  default     = true
}

variable "exclusion_enforcement" {
  description = <<-EOT
    How exclude_projects / exclude_folders are enforced (only relevant when
    auto_onboard = true):
      * "deny" (default) — OPERATIONAL exclusion: scan roles bind at the
        highest node (the ORG in exclude mode, every included folder in
        include mode) and an IAM Deny policy on each excluded project/folder
        blocks deny_permissions for the auditor. Deny beats allow, and both
        inherit — so EVERY new project (root or any folder) is auto-onboarded
        with no re-apply. CAVEAT: the auditor still HOLDS the inherited scan
        roles on excluded scopes; only the permissions in deny_permissions
        are actually blocked. Any permission the roles grant that is missing
        from that list (or that IAM Deny does not support) remains usable
        there. Choose "deny" when exclusions exist to reduce scan noise.
      * "fallback" — HARD exclusion: scopes containing an exclusion are never
        bound at folder/org level; they degrade to per-project bindings.
        Excluded projects receive NO grant at all — there is no access to
        override, even with a compromised credential — but new projects in
        degraded scopes require a re-apply. Choose "fallback" (or
        auto_onboard = false) when exclusions exist for compliance or tenant
        isolation.
  EOT
  type        = string
  default     = "deny"

  validation {
    condition     = contains(["fallback", "deny"], var.exclusion_enforcement)
    error_message = "exclusion_enforcement must be 'fallback' or 'deny'."
  }
}

variable "deny_permissions" {
  description = <<-EOT
    Permissions blocked by the deny policies when exclusion_enforcement =
    "deny", in IAM v2 format (SERVICE.googleapis.com/RESOURCE.ACTION). The
    default blocks the scanner's gateway permissions (projects.get /
    getIamPolicy, which stop the scan pipeline at its first step) PLUS the
    high-value reads granted by the default scan_roles: instance/network
    enumeration, bucket and object reads, log entries, GKE, Cloud SQL,
    BigQuery, service-account and key listing, Pub/Sub, KMS, DNS and Secret
    Manager metadata. This is defense in depth, not a boundary — IAM Deny
    only accepts permissions on Google's "supported in deny policies" list
    (unsupported entries fail at apply), so the granted roles always retain
    some undeniable residue on excluded scopes. For hard exclusion
    guarantees use exclusion_enforcement = "fallback" instead.
  EOT
  type        = list(string)
  default = [
    # Gateway: the scanner discovers a project, then reads its IAM policy.
    "cloudresourcemanager.googleapis.com/projects.get",
    "cloudresourcemanager.googleapis.com/projects.getIamPolicy",
    # Inventory enumeration when CAI is scoped to the excluded project.
    "cloudasset.googleapis.com/assets.searchAllResources",
    "cloudasset.googleapis.com/assets.listResource",
    # Compute & network topology.
    "compute.googleapis.com/instances.list",
    "compute.googleapis.com/instances.get",
    "compute.googleapis.com/disks.list",
    "compute.googleapis.com/firewalls.list",
    "compute.googleapis.com/networks.list",
    "compute.googleapis.com/subnetworks.list",
    # Storage — objects.get/list is the data-exfiltration path.
    "storage.googleapis.com/buckets.list",
    "storage.googleapis.com/buckets.get",
    "storage.googleapis.com/buckets.getIamPolicy",
    "storage.googleapis.com/objects.list",
    "storage.googleapis.com/objects.get",
    # Logs — roles/logging.viewer reads log payloads.
    "logging.googleapis.com/logEntries.list",
    "logging.googleapis.com/logs.list",
    # GKE, Cloud SQL, BigQuery.
    "container.googleapis.com/clusters.list",
    "container.googleapis.com/clusters.get",
    "cloudsql.googleapis.com/instances.list",
    "cloudsql.googleapis.com/instances.get",
    "bigquery.googleapis.com/datasets.get",
    "bigquery.googleapis.com/tables.list",
    "bigquery.googleapis.com/tables.get",
    # roles/bigquery.dataViewer reads row data, not just table metadata.
    "bigquery.googleapis.com/tables.getData",
    # AI/ML: Vertex AI / Agent Platform inventory and inference, Agent
    # Registry inventory. All verified against Google's IAM Deny support list.
    "aiplatform.googleapis.com/endpoints.list",
    "aiplatform.googleapis.com/endpoints.get",
    "aiplatform.googleapis.com/endpoints.predict",
    # explain is an inference call against a deployed model, and ragCorpora.query
    # reads corpus content — both come with roles/aiplatform.viewer itself.
    "aiplatform.googleapis.com/endpoints.explain",
    "aiplatform.googleapis.com/ragCorpora.query",
    "aiplatform.googleapis.com/models.list",
    "aiplatform.googleapis.com/models.get",
    "agentregistry.googleapis.com/agents.list",
    "agentregistry.googleapis.com/agents.get",
    # IAM surface: service accounts and their keys.
    "iam.googleapis.com/serviceAccounts.list",
    "iam.googleapis.com/serviceAccounts.get",
    "iam.googleapis.com/serviceAccountKeys.list",
    # Messaging, monitoring, keys, DNS, secrets metadata.
    "pubsub.googleapis.com/topics.list",
    "pubsub.googleapis.com/subscriptions.list",
    "monitoring.googleapis.com/timeSeries.list",
    "cloudkms.googleapis.com/cryptoKeys.list",
    "dns.googleapis.com/managedZones.list",
    "secretmanager.googleapis.com/secrets.list",
  ]
}

# ==============================================================================
# IAM role sets
# ==============================================================================

variable "organization_roles" {
  description = "Organization-level roles the auditor always receives. Keep these metadata-only: they are visible org-wide regardless of include/exclude scoping. roles/browser lets the scanner enumerate the hierarchy; roles/orgpolicy.policyViewer reads org policies (org-level objects)."
  type        = list(string)
  default = [
    "roles/browser",
    "roles/orgpolicy.policyViewer",
  ]
}

variable "scan_roles" {
  description = "Roles granted at each onboarded scope (folder or project). These carry the actual CSPM read access, so they follow the include/exclude scoping instead of leaking org-wide. roles/policyanalyzer.activityAnalysisViewer backs the identity-inventory service-account last_used lookup (best-effort: the field is null where policyanalyzer.googleapis.com is not enabled on the scanned project)."
  type        = list(string)
  default = [
    # Core CSPM / identity inventory.
    "roles/viewer",               # read-only view of project resources
    "roles/iam.securityReviewer", # read IAM policies across resources

    # Identity inventory enrichment (best-effort: missing data yields null
    # lifecycle fields, collection still succeeds).
    #
    # Policy Analyzer serviceAccountLastAuthentication -> service-account
    # last_used (policyanalyzer.serviceAccountLastAuthenticationActivities.query).
    "roles/policyanalyzer.activityAnalysisViewer",

    # Admin Activity audit logs (logging.logEntries.list) -> service-account
    # created_at / created_by and human users' last_used. Viewer already
    # includes this; kept explicit so the dependency survives if Viewer is
    # ever narrowed.
    "roles/logging.viewer",

    # AI/ML asset discovery — mirrors the standalone AI/ML blueprint
    # (gcp/standalone/aiml). Vertex AI / Agent Platform and Agent Registry
    # inventory, plus the data reads the scanner needs for training data and
    # model artifacts.
    "roles/aiplatform.viewer",    # Vertex AI / Agent Platform asset discovery
    "roles/agentregistry.viewer", # Agent Registry read access
    "roles/bigquery.dataViewer",  # BigQuery data scanning
    "roles/storage.bucketViewer", # Cloud Storage bucket metadata
    "roles/storage.objectViewer", # Cloud Storage object data
  ]
}

variable "custom_role_id" {
  description = "Role ID for the organization-level custom role that carries permissions missing from the built-in scan roles."
  type        = string
  default     = "accuknoxCspmScanner"
}

variable "custom_role_permissions" {
  description = "Permissions for the custom scan role, granted at each onboarded scope alongside scan_roles. Set to [] to skip creating the custom role. Organization scope only — folder scope skips it (a project-level custom role cannot be bound on folders); extend scan_roles there instead."
  type        = list(string)
  default = [
    "storage.buckets.getIamPolicy",
    # AI/ML red teaming against Vertex AI / Agent Platform endpoints, as in
    # the standalone AI/ML blueprint's custom_vertex_ai_predict_role.
    "aiplatform.endpoints.predict",
  ]
}

# ==============================================================================
# Provider plumbing
# ==============================================================================

variable "provider_project_id" {
  description = "Default project for the Google provider. Usually the customer's onboarding/host project."
  type        = string
  default     = ""
}

variable "billing_project_id" {
  description = "Quota/billing project for organization-scoped API calls (Cloud Asset Inventory). REQUIRED in practice: the org-scope asset search needs a quota project with the Cloud Asset API enabled, and the caller needs serviceusage.serviceUsageConsumer on it."
  type        = string
  default     = ""
}

variable "impersonate_service_account" {
  description = "Optional service account to impersonate when applying this configuration."
  type        = string
  default     = ""
}
