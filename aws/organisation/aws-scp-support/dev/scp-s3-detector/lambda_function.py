import gzip
import io
import json
import logging
import os
import time
import urllib.parse
import urllib.request
from datetime import datetime, timezone


logger = logging.getLogger()
logger.setLevel(logging.INFO)

METRIC_NAMESPACE = "AccuKnox/ScpS3Poc"
EMITTED_METRIC_UNITS = {
    "LogFilesProcessed": "Count",
    "CompressedBytesProcessed": "Bytes",
    "CloudTrailRecordsProcessed": "Count",
    "AuthorizationFailures": "Count",
    "ScpMatches": "Count",
    "DuplicateScpEvents": "Count",
    "WebhookFailures": "Count",
    "TimedRecords": "Count",
    "EventAgeSecondsTotal": "Seconds",
    "MaximumEventAgeSeconds": "Seconds",
}
AUTHORIZATION_ERROR_MARKERS = (
    "accessdenied",
    "unauthorized",
    "authorizationerror",
    "notauthorized",
)
SCP_MESSAGE_MARKERS = (
    "service control policy",
    "service-control policy",
    "service control policies",
    "organizations policy",
    "explicit deny in a service control",
)

_s3_client = None
_dynamodb_client = None


def _get_s3_client():
    global _s3_client
    if _s3_client is None:
        import boto3

        _s3_client = boto3.client("s3")
    return _s3_client


def _get_dynamodb_client():
    global _dynamodb_client
    if _dynamodb_client is None:
        import boto3

        _dynamodb_client = boto3.client("dynamodb")
    return _dynamodb_client


def _is_true(value: str) -> bool:
    return value.strip().lower() in {"1", "true", "yes"}


def _parse_json(value):
    if isinstance(value, str):
        return json.loads(value)
    return value


def extract_s3_objects(sqs_body: str) -> list[tuple[str, str]]:
    """Return S3 bucket/key pairs from CloudTrail SNS or S3 notifications."""
    message = _parse_json(sqs_body)

    # SNS without RawMessageDelivery wraps the CloudTrail notification.
    if isinstance(message, dict) and "Message" in message:
        message = _parse_json(message["Message"])

    # CloudTrail native SNS notification and the replay script use this shape.
    if isinstance(message, dict) and "s3Bucket" in message:
        keys = message.get("s3ObjectKey") or []
        if isinstance(keys, str):
            keys = [keys]
        return [(message["s3Bucket"], key) for key in keys]

    # Direct S3 event notifications use this shape.
    if isinstance(message, dict) and "Records" in message:
        objects = []
        for record in message["Records"]:
            if record.get("eventSource") != "aws:s3":
                continue
            bucket = record["s3"]["bucket"]["name"]
            key = urllib.parse.unquote_plus(record["s3"]["object"]["key"])
            objects.append((bucket, key))
        return objects

    # S3 sends this once when a notification configuration is created.
    if isinstance(message, dict) and message.get("Event") == "s3:TestEvent":
        return []

    raise ValueError("Unsupported SQS message body")


def is_authorization_failure(record: dict) -> bool:
    error_code = str(record.get("errorCode") or "").replace("_", "").lower()
    return any(marker in error_code for marker in AUTHORIZATION_ERROR_MARKERS)


def is_scp_denial(record: dict) -> bool:
    if not is_authorization_failure(record):
        return False
    message = str(record.get("errorMessage") or "").lower()
    return any(marker in message for marker in SCP_MESSAGE_MARKERS)


def _parse_event_time_to_unix_seconds(event_time: str) -> int:
    if not event_time:
        return 0
    parsed = datetime.fromisoformat(event_time.replace("Z", "+00:00"))
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return int(parsed.timestamp())


def to_aws_alert_event(record: dict) -> dict:
    user_identity = record.get("userIdentity") or {}
    return {
        "recipientAccountId": record.get("recipientAccountId")
        or user_identity.get("accountId")
        or "",
        "awsRegion": record.get("awsRegion") or "",
        "eventName": record.get("eventName") or "",
        "eventID": record.get("eventID") or "",
        "eventSource": record.get("eventSource") or "",
        "Timestamp": _parse_event_time_to_unix_seconds(record.get("eventTime") or ""),
        "errorCode": record.get("errorCode") or "",
        "errorMessage": record.get("errorMessage") or "",
        "sourceIPAddress": record.get("sourceIPAddress") or "",
        "userIdentity": user_identity,
        "resources": record.get("resources") or [],
        "userAgent": record.get("userAgent") or "",
        "eventType": record.get("eventType") or "",
        "organizationID": os.environ.get("ORGANIZATION_ID", ""),
    }


def _is_conditional_check_failure(error: Exception) -> bool:
    response = getattr(error, "response", {})
    return response.get("Error", {}).get("Code") == "ConditionalCheckFailedException"


def claim_event(event_id: str) -> bool:
    """Claim an event ID and return False when it was already processed."""
    now = int(time.time())
    retention_days = int(os.environ.get("DEDUP_RETENTION_DAYS", "7"))
    table_name = os.environ["DEDUP_TABLE_NAME"]
    try:
        _get_dynamodb_client().put_item(
            TableName=table_name,
            Item={
                "event_id": {"S": event_id},
                "status": {"S": "IN_PROGRESS"},
                "claim_expires_at": {"N": str(now + 300)},
                "expires_at": {"N": str(now + retention_days * 86400)},
            },
            ConditionExpression=(
                "attribute_not_exists(event_id) OR claim_expires_at < :now"
            ),
            ExpressionAttributeValues={":now": {"N": str(now)}},
        )
        return True
    except Exception as error:
        if _is_conditional_check_failure(error):
            return False
        raise


def complete_event(event_id: str) -> None:
    _get_dynamodb_client().update_item(
        TableName=os.environ["DEDUP_TABLE_NAME"],
        Key={"event_id": {"S": event_id}},
        UpdateExpression="SET #status = :complete REMOVE claim_expires_at",
        ExpressionAttributeNames={"#status": "status"},
        ExpressionAttributeValues={":complete": {"S": "COMPLETE"}},
    )


def release_event(event_id: str) -> None:
    _get_dynamodb_client().delete_item(
        TableName=os.environ["DEDUP_TABLE_NAME"],
        Key={"event_id": {"S": event_id}},
    )


def send_alert(record: dict) -> None:
    payload = {
        "tenant_id": os.environ.get("TENANT_ID", ""),
        "topic": os.environ.get("TOPIC", "awsalerts"),
        "component_name": os.environ.get("COMPONENT_NAME", "cloud-governance"),
        "type": "aws-scp",
        "payload": to_aws_alert_event(record),
    }
    request = urllib.request.Request(
        os.environ["WEBHOOK_URL"],
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(request, timeout=10) as response:
        if response.status < 200 or response.status >= 300:
            raise RuntimeError(f"Webhook returned HTTP {response.status}")


def _empty_metrics() -> dict:
    return {
        "MessagesProcessed": 0,
        "LogFilesProcessed": 0,
        "CompressedBytesProcessed": 0,
        "CloudTrailRecordsProcessed": 0,
        "ErrorRecords": 0,
        "AuthorizationFailures": 0,
        "ScpMatches": 0,
        "DuplicateScpEvents": 0,
        "WebhookSuccesses": 0,
        "WebhookFailures": 0,
        "TimedRecords": 0,
        "EventAgeSecondsTotal": 0,
        "MaximumEventAgeSeconds": 0,
    }


def _merge_metrics(total: dict, addition: dict) -> None:
    for name, value in addition.items():
        total[name] += value


def process_log_file(bucket: str, key: str) -> dict:
    metrics = _empty_metrics()
    if not key.endswith(".json.gz") or "/CloudTrail/" not in key:
        logger.info("Skipping non-CloudTrail object s3://%s/%s", bucket, key)
        return metrics

    response = _get_s3_client().get_object(Bucket=bucket, Key=key)
    compressed = response["Body"].read()
    metrics["LogFilesProcessed"] = 1
    metrics["CompressedBytesProcessed"] = int(
        response.get("ContentLength", len(compressed))
    )

    with gzip.GzipFile(fileobj=io.BytesIO(compressed), mode="rb") as stream:
        log_document = json.loads(stream.read().decode("utf-8"))

    dry_run = _is_true(os.environ.get("DRY_RUN", "true"))
    current_time = int(time.time())
    for record in log_document.get("Records", []):
        metrics["CloudTrailRecordsProcessed"] += 1
        event_timestamp = _parse_event_time_to_unix_seconds(record.get("eventTime") or "")
        if event_timestamp:
            event_age = max(0, current_time - event_timestamp)
            metrics["TimedRecords"] += 1
            metrics["EventAgeSecondsTotal"] += event_age
            metrics["MaximumEventAgeSeconds"] = max(
                metrics["MaximumEventAgeSeconds"], event_age
            )
        if record.get("errorCode"):
            metrics["ErrorRecords"] += 1
        if is_authorization_failure(record):
            metrics["AuthorizationFailures"] += 1
        if not is_scp_denial(record):
            continue

        metrics["ScpMatches"] += 1
        event_id = record.get("eventID")
        if not event_id:
            logger.warning("Skipping SCP candidate without eventID")
            continue
        if not claim_event(event_id):
            metrics["DuplicateScpEvents"] += 1
            continue

        try:
            if not dry_run:
                send_alert(record)
                metrics["WebhookSuccesses"] += 1
            complete_event(event_id)
        except Exception:
            if not dry_run:
                metrics["WebhookFailures"] += 1
            release_event(event_id)
            raise

    logger.info("Processed s3://%s/%s metrics=%s", bucket, key, metrics)
    return metrics


def emit_metrics(metrics: dict, function_name: str) -> None:
    metric_definitions = [
        {"Name": name, "Unit": unit}
        for name, unit in EMITTED_METRIC_UNITS.items()
    ]
    document = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": METRIC_NAMESPACE,
                    "Dimensions": [["FunctionName"]],
                    "Metrics": metric_definitions,
                }
            ],
        },
        "FunctionName": function_name,
        **metrics,
    }
    print(json.dumps(document, separators=(",", ":")))


def lambda_handler(event, context):
    totals = _empty_metrics()
    failures = []

    for sqs_record in event.get("Records", []):
        message_id = sqs_record.get("messageId", "unknown")
        try:
            objects = extract_s3_objects(sqs_record["body"])
            for bucket, key in objects:
                _merge_metrics(totals, process_log_file(bucket, key))
            totals["MessagesProcessed"] += 1
        except Exception:
            logger.exception("Failed to process SQS message %s", message_id)
            failures.append({"itemIdentifier": message_id})

    function_name = getattr(context, "function_name", "scp-s3-poc")
    emit_metrics(totals, function_name)
    return {"batchItemFailures": failures}
