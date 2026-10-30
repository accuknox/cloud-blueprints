import base64
import json
import os
from types import SimpleNamespace
from typing import Any

try:
    import boto3
    from botocore.exceptions import ClientError
except ModuleNotFoundError:  # pragma: no cover - local test fallback
    boto3 = SimpleNamespace()

    class ClientError(Exception):
        def __init__(self, response: dict[str, Any] | None = None, operation_name: str = ""):
            super().__init__(operation_name)
            self.response = response or {}


MANAGED_BY_TAG_VALUE = "accuknox-pps"
SUPPORTED_ACTIONS = {"CREATE", "UPDATE", "DELETE"}


class ValidationError(Exception):
    """Raised when the incoming event is missing required inputs."""


def lambda_handler(event: dict[str, Any], _context: Any) -> dict[str, Any]:
    try:
        if _is_check_request(event):
            return _response(200, {"status": "active"})

        request = _parse_request(event)
        action = request["action"]

        organizations = _organizations_client()
        if action in {"CREATE", "UPDATE"}:
            target_ids = _resolve_target_ids(request)
            result = _handle_upsert(organizations, request, target_ids)
        else:
            result = _handle_delete(organizations, request)

        return _response(200, {"status": "ok", "action": action, **result})
    except ValidationError as exc:
        return _response(400, {"status": "error", "message": str(exc)})
    except ClientError as exc:
        error = exc.response.get("Error", {})
        message = error.get("Message", str(exc))
        return _response(
            _status_code_for_aws_error(error.get("Code")),
            {
                "status": "error",
                "message": message,
                "aws_error_code": error.get("Code"),
            },
        )
    except Exception as exc:  # pragma: no cover - defensive fallback
        return _response(500, {"status": "error", "message": str(exc)})


def _is_check_request(event: dict[str, Any]) -> bool:
    request_context = event.get("requestContext", {})
    http_context = request_context.get("http", {})
    method = str(http_context.get("method", "")).upper()
    path = str(event.get("rawPath") or request_context.get("path") or "")
    route_key = str(event.get("routeKey") or request_context.get("routeKey") or "")
    return (method == "GET" and path == "/check") or route_key == "GET /check"


def _organizations_client() -> Any:
    client_factory = getattr(boto3, "client", None)
    if client_factory is None:
        raise RuntimeError("boto3 is required to create the AWS Organizations client")
    return client_factory("organizations")


def _handle_upsert(
    organizations: Any, request: dict[str, Any], target_ids: list[str]
) -> dict[str, Any]:
    _require_fields(request, "policy_id", "workspace_id")

    workspace_id = request["workspace_id"]
    policy_id = request["policy_id"]

    try:
        aws_policy_id = _find_policy_by_tags(organizations, policy_id, workspace_id)

        update_request: dict[str, Any] = {"PolicyId": aws_policy_id}
        if not _is_missing(request.get("content")):
            update_request["Content"] = _policy_document_json(request["content"])
        if not _is_missing(request.get("description")):
            update_request["Description"] = request["description"]
        if not _is_missing(request.get("name")):
            update_request["Name"] = request["name"]

        if len(update_request) > 1:
            organizations.update_policy(
                **update_request,
            )
    except ValidationError:
        # If policy not found, create it (Upsert logic)
        _require_fields(request, "name", "content")
        response = organizations.create_policy(
            Content=_policy_document_json(request["content"]),
            Name=request["name"],
            Description=request.get("description", ""),
            Type="SERVICE_CONTROL_POLICY",
        )
        aws_policy_id = response["Policy"]["PolicySummary"]["Id"]

        try:
            _tag_policy(organizations, aws_policy_id, request)
        except ClientError as e:
            try:
                organizations.delete_policy(PolicyId=aws_policy_id)
            except ClientError:
                pass
            raise ValidationError(
                f"Policy created but tagging failed, rolled back. Error: {e}"
            ) from e

    attachment_changed = _ensure_exact_target_ids(
        organizations,
        aws_policy_id,
        target_ids,
    )

    response = {
        "aws_policy_id": aws_policy_id,
        "attachment_changed": attachment_changed,
        "attachment_reconciled": bool(target_ids),
    }
    if target_ids:
        response["target_ids"] = target_ids
    return response


def _handle_delete(organizations: Any, request: dict[str, Any]) -> dict[str, Any]:
    _require_fields(request, "policy_id", "workspace_id")

    aws_policy_id = _find_policy_by_tags(
        organizations,
        request["policy_id"],
        request["workspace_id"],
    )

    detached_target_ids = _detach_all_targets(organizations, aws_policy_id)
    organizations.delete_policy(PolicyId=aws_policy_id)

    return {
        "detached_target_ids": detached_target_ids,
        "attachment_changed": bool(detached_target_ids),
    }


def _parse_request(event: dict[str, Any]) -> dict[str, Any]:
    body = event.get("body", event)
    if isinstance(body, str):
        if event.get("isBase64Encoded"):
            body = base64.b64decode(body).decode("utf-8")
        try:
            body = json.loads(body)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"request body must be valid JSON: {exc}") from exc

    if not isinstance(body, dict):
        raise ValidationError("request body must decode to an object")

    action = str(body.get("action", "")).strip().upper()
    if action not in SUPPORTED_ACTIONS:
        raise ValidationError(
            f"action must be one of {sorted(SUPPORTED_ACTIONS)}"
        )

    normalized = dict(body)
    normalized["action"] = action
    return normalized



def _resolve_target_ids(request: dict[str, Any]) -> list[str]:
    raw_target_ids = request.get("target_ids")
    if raw_target_ids is not None:
        if not isinstance(raw_target_ids, list):
            raise ValidationError("target_ids must be a list of non-empty strings")
        target_ids = _normalize_target_ids(raw_target_ids)
        return target_ids

    return []


def _normalize_target_ids(values: list[Any]) -> list[str]:
    normalized: list[str] = []
    seen: set[str] = set()
    for value in values:
        target_id = str(value).strip()
        if not target_id:
            raise ValidationError("target_ids must contain only non-empty strings")
        if target_id in seen:
            continue
        seen.add(target_id)
        normalized.append(target_id)
    return normalized


def _require_fields(request: dict[str, Any], *fields: str) -> None:
    missing = [field for field in fields if _is_missing(request.get(field))]
    if missing:
        raise ValidationError(f"missing required fields: {', '.join(missing)}")


def _is_missing(value: Any) -> bool:
    if value is None:
        return True
    if isinstance(value, str):
        return value.strip() == ""
    return False


def _policy_document_json(document: Any) -> str:
    if isinstance(document, str):
        try:
            json.loads(document)
        except json.JSONDecodeError as exc:
            raise ValidationError(f"scp content must be valid JSON: {exc}") from exc
        return document

    try:
        return json.dumps(document, separators=(",", ":"), sort_keys=True)
    except TypeError as exc:
        raise ValidationError(f"scp content is not JSON serializable: {exc}") from exc


def _tag_policy(
    organizations: Any, aws_policy_id: str, request: dict[str, Any]
) -> None:
    tags = [
        {"Key": "managed_by", "Value": MANAGED_BY_TAG_VALUE},
    ]
    for key in ("tenant_id", "workspace_id", "policy_id"):
        if key in request and not _is_missing(request.get(key)):
            tags.append({"Key": key, "Value": str(request[key])})

    organizations.tag_resource(ResourceId=aws_policy_id, Tags=tags)


def _ensure_target_ids_attached(
    organizations: Any, aws_policy_id: str, target_ids: list[str]
) -> bool:
    attached_targets = _list_target_ids_for_policy(organizations, aws_policy_id)
    changed = False
    for target_id in target_ids:
        if target_id in attached_targets:
            continue
        organizations.attach_policy(PolicyId=aws_policy_id, TargetId=target_id)
        attached_targets.add(target_id)
        changed = True
    return changed


def _ensure_exact_target_ids(
    organizations: Any, aws_policy_id: str, target_ids: list[str]
) -> bool:
    desired_targets = set(target_ids)
    current_targets = _list_target_ids_for_policy(organizations, aws_policy_id)
    changed = False
    # If desired targets is empty. Detach
    if len(desired_targets) == 0:
        _detach_all_targets(organizations, aws_policy_id)
        changed = True
        return changed

    for target_id in sorted(current_targets - desired_targets):
        organizations.detach_policy(PolicyId=aws_policy_id, TargetId=target_id)
        changed = True

    for target_id in target_ids:
        if target_id in current_targets:
            continue
        organizations.attach_policy(PolicyId=aws_policy_id, TargetId=target_id)
        changed = True

    return changed


def _detach_all_targets(organizations: Any, aws_policy_id: str) -> list[str]:
    attached_targets = sorted(_list_target_ids_for_policy(organizations, aws_policy_id))
    for target_id in attached_targets:
        organizations.detach_policy(PolicyId=aws_policy_id, TargetId=target_id)
    return attached_targets


def _list_target_ids_for_policy(organizations: Any, aws_policy_id: str) -> set[str]:
    target_ids: set[str] = set()
    next_token = None
    while True:
        params = {"PolicyId": aws_policy_id}
        if next_token:
            params["NextToken"] = next_token
        response = organizations.list_targets_for_policy(**params)
        for target in response.get("Targets", []):
            target_ids.add(target["TargetId"])
        next_token = response.get("NextToken")
        if not next_token:
            return target_ids


def _status_code_for_aws_error(error_code: str | None) -> int:
    if error_code in {"InvalidInputException", "MalformedPolicyDocumentException", "TargetNotFoundException"}:
        return 400
    if error_code == "AccessDeniedException":
        return 403
    if error_code == "PolicyNotFoundException":
        return 404
    if error_code in {"DuplicatePolicyException", "ConstraintViolationException", "PolicyTypeNotEnabledException"}:
        return 409
    return 502


def _response(status_code: int, body: dict[str, Any]) -> dict[str, Any]:
    return {
        "statusCode": status_code,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }

def _find_policy_by_tags(
    organizations: Any, policy_id: str, workspace_id: str
) -> str:
    paginator = organizations.get_paginator("list_policies")

    for page in paginator.paginate(Filter="SERVICE_CONTROL_POLICY"):
        for policy in page.get("Policies", []):
            aws_policy_id = policy["Id"]

            tags_response = organizations.list_tags_for_resource(
                ResourceId=aws_policy_id
            )

            tags = {tag["Key"]: tag["Value"] for tag in tags_response.get("Tags", [])}

            if (
                tags.get("policy_id") == str(policy_id)
                and tags.get("workspace_id") == str(workspace_id)
            ):
                return aws_policy_id

    raise ValidationError(
        f"No policy found for policy_id={policy_id}, workspace_id={workspace_id}"
    )