terraform {
  required_version = ">= 1.7.0"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }
}

########################################################
########################################################

variable "accuknox_app_client_id" {
  description = "Client (application) ID of the AccuKnox enterprise app / service principal in the customer tenant, used for Graph permission grants and the Power Platform application user."
  type        = string
  default     = "384d0c6d-8e35-489a-8833-346c5bbf2dbc"

  validation {
    condition     = can(regex("(?i)^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", trimspace(var.accuknox_app_client_id)))
    error_message = "accuknox_app_client_id must be a client ID (GUID)."
  }
}

variable "enable_powerplatform_registration" {
  description = "Register the AccuKnox application as an application user in selected Dataverse environments through the BAP/Dataverse REST APIs. Requires Power Platform/Dataverse administrator permissions. Set to false to skip."
  type        = bool
  default     = true
}

variable "powerplatform_environment_selection" {
  description = "'all' = every Dataverse environment the operator can access from the BAP API; 'specific' = only environments listed in only_environment_display_names."
  type        = string
  default     = "all"

  validation {
    condition     = contains(["all", "specific"], var.powerplatform_environment_selection)
    error_message = "powerplatform_environment_selection must be 'all' or 'specific'."
  }
}

variable "only_environment_display_names" {
  description = "Environment display names to onboard when powerplatform_environment_selection = 'specific'. Ignored when selection = 'all'."
  type        = list(string)
  default     = []
}

variable "dataverse_security_role_name" {
  description = "Dataverse security role assigned to the AccuKnox application user."
  type        = string
  default     = "Service Reader"
}

variable "powerplatform_request_timeout_seconds" {
  description = "Maximum seconds per Power Platform authentication or HTTP request (requires GNU timeout, curl, and jq)."
  type        = number
  default     = 30

  validation {
    condition     = var.powerplatform_request_timeout_seconds >= 5 && var.powerplatform_request_timeout_seconds <= 300 && floor(var.powerplatform_request_timeout_seconds) == var.powerplatform_request_timeout_seconds
    error_message = "powerplatform_request_timeout_seconds must be an integer between 5 and 300."
  }
}

variable "powerplatform_discovery_timeout_seconds" {
  description = "Maximum seconds for the entire BAP environment discovery, including all pages."
  type        = number
  default     = 120

  validation {
    condition     = var.powerplatform_discovery_timeout_seconds >= 5 && var.powerplatform_discovery_timeout_seconds <= 600 && floor(var.powerplatform_discovery_timeout_seconds) == var.powerplatform_discovery_timeout_seconds
    error_message = "powerplatform_discovery_timeout_seconds must be an integer between 5 and 600."
  }
}

variable "powerplatform_skip_environment_ids" {
  description = "Environment IDs where registration is known to be unsupported. Creation is skipped, but existing users are still cleaned up on destroy."
  type        = set(string)
  default     = []
}

variable "powerplatform_api_version" {
  description = "BAP API version used for environment discovery."
  type        = string
  default     = "2021-04-01"
}

########################################################
# Power Platform (Dataverse) registration via REST API
# Uses BAP for discovery and Dataverse REST APIs for app-user registration.
########################################################

data "external" "powerplatform_environments" {
  count = var.enable_powerplatform_registration ? 1 : 0

  program = ["timeout", "--kill-after=5s", "${var.powerplatform_discovery_timeout_seconds}s", "bash", "-c", <<-EOT
    set -euo pipefail
    trap 'echo "Power Platform discovery exceeded its total time limit; no inventory returned" >&2; exit 124' TERM
    page=0
    command -v jq >/dev/null || { echo "jq is required for Power Platform discovery" >&2; exit 1; }
    work=$(mktemp -d)
    trap 'rm -rf "$work"' EXIT
    touch "$work/environments" "$work/visited"
    url="https://api.bap.microsoft.com/providers/Microsoft.BusinessAppPlatform/environments?api-version=$1&%24expand=properties.linkedEnvironmentMetadata"
    while [ -n "$url" ]; do
      case "$url" in
        https://api.bap.microsoft.com/*) ;;
        *) echo "Unexpected BAP continuation URL" >&2; exit 1 ;;
      esac
      if grep -Fxq "$url" "$work/visited"; then
        echo "Repeated BAP continuation URL" >&2
        exit 1
      fi
      printf '%s\n' "$url" >> "$work/visited"
      page=$((page + 1))
      if timeout --foreground --kill-after=5s "$2" az rest --method get --url "$url" \
        --resource "https://api.bap.microsoft.com/" --only-show-errors -o json > "$work/page"; then
        :
      else
        rc=$?
        echo "Power Platform discovery failed on page $page (exit $rc, per-request limit $2 seconds); no inventory returned" >&2
        exit "$rc"
      fi
      jq -e '.value | type == "array"' "$work/page" >/dev/null
      jq -c '.value[] | select(.properties.linkedEnvironmentMetadata.instanceUrl != null and .properties.linkedEnvironmentMetadata.instanceUrl != "") |
        {id: .name, name: .properties.displayName, url: .properties.linkedEnvironmentMetadata.instanceUrl, state: .properties.linkedEnvironmentMetadata.instanceState}' \
        "$work/page" >> "$work/environments"
      url=$(jq -r '.nextLink // ."@odata.nextLink" // empty' "$work/page")
    done
    jq -s '{envs: (unique_by(.id) | tojson)}' "$work/environments"
  EOT
    , "powerplatform-discovery", var.powerplatform_api_version, tostring(var.powerplatform_request_timeout_seconds)
  ]
}

locals {
  pp_all_envs = var.enable_powerplatform_registration ? jsondecode(
    data.external.powerplatform_environments[0].result.envs
  ) : []

  # Keep resource membership stable when environment health changes.
  dataverse_envs = {
    for env in local.pp_all_envs :
    env.id => {
      id    = env.id
      name  = env.name
      url   = trimsuffix(env.url, "/")
      state = coalesce(try(env.state, null), "Unknown")
    }
    if var.powerplatform_environment_selection == "all" ||
    contains(var.only_environment_display_names, env.name)
  }
}
resource "terraform_data" "pp_app_user" {
  for_each = local.dataverse_envs

  input = {
    url             = each.value.url
    env_id          = each.value.id
    env_name        = each.value.name
    app_id          = trimspace(var.accuknox_app_client_id)
    role_name       = var.dataverse_security_role_name
    state           = each.value.state
    skip            = contains(var.powerplatform_skip_environment_ids, each.key)
    timeout_seconds = var.powerplatform_request_timeout_seconds
  }

  triggers_replace = {
    url       = each.value.url
    app_id    = trimspace(var.accuknox_app_client_id)
    role_name = var.dataverse_security_role_name
  }

  provisioner "local-exec" {
    when        = create
    interpreter = ["/bin/bash", "-c"]
    quiet       = true

    environment = {
      PP_URL     = self.input.url
      PP_APP     = self.input.app_id
      PP_ROLE    = self.input.role_name
      PP_ENV     = self.input.env_name
      PP_STATE   = self.input.state
      PP_SKIP    = tostring(self.input.skip)
      PP_TIMEOUT = tostring(self.input.timeout_seconds)
    }

    command = <<-EOT
      set -euo pipefail
      base="$PP_URL/api/data/v9.2"
      umask 077
      work=$(mktemp -d)
      err="$work/error"
      touch "$err"
      trap 'rm -rf "$work"' EXIT

      authenticate() {
        command -v curl >/dev/null && command -v jq >/dev/null || fail "curl and jq are required"
        local token
        token=$(timeout --kill-after=5s "$PP_TIMEOUT" az account get-access-token \
          --resource "$PP_URL" --query accessToken -o tsv --only-show-errors 2>"$err") || fail "token acquisition failed"
        [ -n "$token" ] || fail "token acquisition returned an empty token"
        printf 'Authorization: Bearer %s\n' "$token" > "$work/auth"
      }
      # rest METHOD URL [jq filter] [JSON body]
      # Do not retry writes with unknown outcomes.
      rest() {
        local method="$1" url="$2" query="$${3:-empty}" body="$${4:-}" status rc
        local args=()
        [ -z "$body" ] || args+=(--data-binary "$body")
        : > "$err"
        status=$(curl --disable --silent --show-error --globoff --proto '=https' \
          --connect-timeout "$PP_TIMEOUT" --max-time "$PP_TIMEOUT" \
          --request "$method" --url "$url" \
          --header "@$work/auth" --header 'Accept: application/json' \
          --header 'Content-Type: application/json' --header 'OData-Version: 4.0' \
          --header 'Prefer: return=representation' \
          --output "$work/response" --write-out '%%{http_code}' "$${args[@]}" 2>"$err") || {
            rc=$?
            case "$rc" in
              6|7|28) printf 'Unavailable transport (curl %s)\n' "$rc" >> "$err" ;;
            esac
            return "$rc"
          }
        case "$status" in
          2??) ;;
          *) printf 'HTTP %s\n' "$status" > "$err"
             cat "$work/response" >> "$err"
             return 1 ;;
        esac
        if [ "$method" = GET ]; then
          jq -e '.value | type == "array"' "$work/response" >/dev/null 2>"$err" || {
            echo 'Invalid Dataverse collection response' >> "$err"
            return 1
          }
        fi
        [ "$query" = empty ] || jq -r "$query" "$work/response" 2>"$err"
      }
      fail() {
        echo "ERROR Power Platform: $PP_ENV - $1" >&2
        cat "$err" >&2
        exit 1
      }
      read_failed() {
        if [ "$1" = 124 ] || [ "$1" = 137 ] || grep -qiE '^HTTP (403|404|502|503|504)$|^Unavailable transport' "$err"; then
          echo "SKIP Power Platform: $PP_ENV - unavailable or access denied ($2); use -replace to retry" >&2
          cat "$err" >&2
          exit 0
        fi
        fail "$2"
      }

      if [ "$PP_SKIP" = true ]; then
        echo "SKIP Power Platform: $PP_ENV - explicitly excluded from registration"
        exit 0
      fi
      case "$PP_STATE" in
        Ready|Unknown) ;;
        *) echo "SKIP Power Platform: $PP_ENV - Dataverse state $PP_STATE; use -replace to retry"; exit 0 ;;
      esac

      authenticate

      role_literal=$(printf '%s' "$PP_ROLE" | sed "s/'/''/g")
      role_encoded=""
      export LC_ALL=C
      for ((i=0; i<$${#role_literal}; i++)); do
        c="$${role_literal:i:1}"
        printf -v hex '%%%02X' "'$c"
        role_encoded+="$hex"
      done
      # Soft-deleted users can block registration; check them first.
      user=$(rest GET "$base/systemusers?%24select=systemuserid,_businessunitid_value,isdisabled,deletedstate&%24filter=applicationid%20eq%20$PP_APP&%24orderby=deletedstate%20desc&%24top=1" \
        '.value[0] // empty | if .deletedstate == 1 then "SOFT_DELETED" elif .deletedstate == 0 then [.systemuserid, ._businessunitid_value, .isdisabled] | @tsv else error("Unknown user deleted state") end') || read_failed "$?" "app user lookup failed"
      if [ "$user" = SOFT_DELETED ]; then
        echo "SKIP Power Platform: $PP_ENV - soft-deleted application user requires administrator resolution; use -replace after resolution to retry" >&2
        exit 0
      fi
      uid=""; bu=""; disabled=""; roleid=""
      if [ -n "$user" ]; then
        IFS=$'\t' read -r uid bu disabled <<< "$user"
        roleid=$(rest GET "$base/roles?%24select=roleid&%24filter=name%20eq%20'$role_encoded'%20and%20_businessunitid_value%20eq%20$bu" \
          '.value[0].roleid // empty') || read_failed "$?" "role lookup failed"
      else
        unit=$(rest GET "$base/businessunits?%24select=businessunitid&%24filter=parentbusinessunitid%20eq%20null&%24expand=business_unit_roles(%24select=roleid;%24filter=name%20eq%20'$role_encoded')" \
          '.value[0] // empty | [.businessunitid, (.business_unit_roles[0].roleid // "")] | @tsv') || read_failed "$?" "business unit and role lookup failed"
        [ -n "$unit" ] || fail "root business unit not found"
        IFS=$'\t' read -r bu roleid <<< "$unit"
        [ -n "$bu" ] || fail "root business unit not found"
      fi
      [ -n "$roleid" ] || fail "role '$PP_ROLE' not found in business unit $bu"

      if [ -z "$uid" ]; then
        if uid=$(rest POST "$base/systemusers?%24select=systemuserid" \
          '.systemuserid // empty' \
          "{\"applicationid\":\"$PP_APP\",\"businessunitid@odata.bind\":\"/businessunits($bu)\",\"systemuserroles_association@odata.bind\":[\"/roles($roleid)\"]}"); then
          [ -n "$uid" ] || fail "app user creation returned no ID"
          echo "OK Power Platform: $PP_ENV"
          exit 0
        elif grep -qiE '^HTTP 403$' "$err"; then
          echo "SKIP Power Platform: $PP_ENV - app user registration denied; use -replace to retry" >&2
          cat "$err" >&2
          exit 0
        else
          fail "app user creation failed"
        fi
      elif [ "$disabled" = True ] || [ "$disabled" = true ]; then
        if ! rest PATCH "$base/systemusers($uid)" \
          empty '{"isdisabled":false}'; then
          if grep -q '^HTTP 403$' "$err"; then
            echo "SKIP Power Platform: $PP_ENV - activation denied; user remains disabled; use -replace to retry" >&2
            cat "$err" >&2
            exit 0
          fi
          if grep -q '^HTTP 400$' "$err" && jq -e '.error.code == "0x80048357"' "$work/response" >/dev/null 2>&1; then
            echo "SKIP Power Platform: $PP_ENV - application user was soft-deleted; use -replace after administrator resolution to retry" >&2
            cat "$err" >&2
            exit 0
          fi
          fail "activation failed"
        fi
      fi

      if ! rest POST "$base/systemusers($uid)/systemuserroles_association/%24ref" \
        empty \
        "{\"@odata.id\":\"$base/roles($roleid)\"}"; then
        cat "$err" >&2
        assigned=$(rest GET "$base/systemusers($uid)/systemuserroles_association?%24select=roleid&%24filter=roleid%20eq%20$roleid" \
          '.value[0].roleid // empty') || fail "role assignment verification failed"
        [ "$assigned" = "$roleid" ] || fail "role assignment failed"
      fi
      echo "OK Power Platform: $PP_ENV"
    EOT
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["/bin/bash", "-c"]
    quiet       = true

    environment = {
      PP_URL  = self.input.url
      PP_APP  = self.input.app_id
      PP_ROLE = self.input.role_name
      PP_ENV  = self.input.env_name
      # Support resources created before timeout was stored in state.
      PP_TIMEOUT = tostring(try(self.input.timeout_seconds, 30))
    }

    command = <<-EOT
      set -euo pipefail
      base="$PP_URL/api/data/v9.2"
      umask 077
      work=$(mktemp -d)
      err="$work/error"
      touch "$err"
      trap 'rm -rf "$work"' EXIT
      authenticate() {
        command -v curl >/dev/null && command -v jq >/dev/null || fail "curl and jq are required"
        local token
        token=$(timeout --kill-after=5s "$PP_TIMEOUT" az account get-access-token \
          --resource "$PP_URL" --query accessToken -o tsv --only-show-errors 2>"$err") || fail "token acquisition failed"
        [ -n "$token" ] || fail "token acquisition returned an empty token"
        printf 'Authorization: Bearer %s\n' "$token" > "$work/auth"
      }
      # rest METHOD URL [jq filter] [JSON body]
      # Do not retry writes with unknown outcomes.
      rest() {
        local method="$1" url="$2" query="$${3:-empty}" body="$${4:-}" status rc
        local args=()
        [ -z "$body" ] || args+=(--data-binary "$body")
        : > "$err"
        status=$(curl --disable --silent --show-error --globoff --proto '=https' \
          --connect-timeout "$PP_TIMEOUT" --max-time "$PP_TIMEOUT" \
          --request "$method" --url "$url" \
          --header "@$work/auth" --header 'Accept: application/json' \
          --header 'Content-Type: application/json' --header 'OData-Version: 4.0' \
          --header 'Prefer: return=representation' \
          --output "$work/response" --write-out '%%{http_code}' "$${args[@]}" 2>"$err") || {
            rc=$?
            case "$rc" in
              6|7|28) printf 'Unavailable transport (curl %s)\n' "$rc" >> "$err" ;;
            esac
            return "$rc"
          }
        case "$status" in
          2??) ;;
          *) printf 'HTTP %s\n' "$status" > "$err"
             cat "$work/response" >> "$err"
             return 1 ;;
        esac
        if [ "$method" = GET ]; then
          jq -e '.value | type == "array"' "$work/response" >/dev/null 2>"$err" || {
            echo 'Invalid Dataverse collection response' >> "$err"
            return 1
          }
        fi
        [ "$query" = empty ] || jq -r "$query" "$work/response" 2>"$err"
      }
      fail() {
        echo "ERROR Power Platform: $PP_ENV - $1; cleanup incomplete" >&2
        cat "$err" >&2
        exit 1
      }

      authenticate

      user=$(rest GET "$base/systemusers?%24select=systemuserid,isdisabled&%24filter=applicationid%20eq%20$PP_APP%20and%20deletedstate%20eq%200" \
        '.value[0] // empty | if (.systemuserid | type) != "string" or (.isdisabled | type) != "boolean" then error("Invalid user ID or disabled status") else [.systemuserid, .isdisabled] | @tsv end') || fail "app user lookup failed"
      if [ -z "$user" ]; then
        echo "SKIP Power Platform: $PP_ENV - app user absent"
        exit 0
      fi
      IFS=$'\t' read -r uid disabled <<< "$user"

      if [ "$disabled" != true ]; then
        rest PATCH "$base/systemusers($uid)" \
          empty '{"isdisabled":true}' || fail "disable failed"
      fi

      role_literal=$(printf '%s' "$PP_ROLE" | sed "s/'/''/g")
      role_encoded=""
      export LC_ALL=C
      for ((i=0; i<$${#role_literal}; i++)); do
        c="$${role_literal:i:1}"
        printf -v hex '%%%02X' "'$c"
        role_encoded+="$hex"
      done

      roleid=$(rest GET "$base/systemusers($uid)/systemuserroles_association?%24select=roleid,name&%24filter=name%20eq%20'$role_encoded'" \
        '.value[0].roleid // empty') || fail "role lookup failed"

      if [ -n "$roleid" ]; then
        rest DELETE "$base/systemusers($uid)/systemuserroles_association($roleid)/%24ref" \
          || fail "role removal failed"
      fi

      echo "OK Power Platform disabled, role '$PP_ROLE' removed, app user retained: $PP_ENV"
    EOT
  }
}


output "powerplatform_selected_environments" {
  description = "Environments selected for AccuKnox app-user registration (display name => Dataverse URL)."
  value       = { for id, env in local.dataverse_envs : env.name => env.url }
}

output "powerplatform_registration_resource_ids" {
  description = "Terraform resource IDs for the selected Dataverse app-user registration operations. Runtime API success/failure details are emitted by the local-exec provisioners."
  value       = { for id, registration in terraform_data.pp_app_user : id => registration.id }
}
