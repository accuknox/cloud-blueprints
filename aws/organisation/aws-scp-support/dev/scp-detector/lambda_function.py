import json
import logging
import os
from datetime import datetime, timezone

import urllib3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

http = urllib3.PoolManager()

WEBHOOK_URL = os.environ.get(
    "WEBHOOK_URL",
    "http://knox-gw.dev.accuknox.com:8080/aws/alerts",
)


def _parse_event_time_to_unix_seconds(event_time: str) -> int:
    if not event_time:
        return 0

    dt = datetime.fromisoformat(event_time.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return int(dt.timestamp())


def to_aws_alert_event(event: dict) -> dict:
    resources = event.get("resources") or []
    detail = event.get("detail") or {}
    user_identity = detail.get("userIdentity") or {}

    return {
        "recipientAccountId": detail.get("recipientAccountId")
        or event.get("account")
        or user_identity.get("accountId")
        or "",
        "awsRegion": detail.get("awsRegion") or "",
        "eventName": detail.get("eventName") or "",
        "eventSource": detail.get("eventSource") or "",
        "Timestamp": _parse_event_time_to_unix_seconds(detail.get("eventTime") or ""),
        "errorCode": detail.get("errorCode") or "",
        "errorMessage": detail.get("errorMessage") or "",
        "sourceIPAddress": detail.get("sourceIPAddress") or "",
        "userIdentity": user_identity,
        "resources": resources,
        "userAgent": detail.get("userAgent") or "",
        "eventType": detail.get("eventType") or "",
        "organizationID": os.environ.get("ORGANIZATION_ID", ""),
    }


def lambda_handler(event, context):
    logger.info("Received event: %s", json.dumps(event))

    payload = {
        "tenant_id": os.environ.get("TENANT_ID", ""),
        "topic": os.environ.get("TOPIC", "awsalerts"),
        "component_name": os.environ.get("COMPONENT_NAME", "cloud-governance"),
        "type": "aws-scp",
        "payload": to_aws_alert_event(event),
    }

    logger.info("Sending payload: %s", json.dumps(payload))

    try:
        response = http.request(
            "POST",
            WEBHOOK_URL,
            body=json.dumps(payload).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
            },
        )

        logger.info(
            "Webhook response status: %s body: %s",
            response.status,
            response.data.decode("utf-8"),
        )

        return {
            "statusCode": response.status,
            "body": response.data.decode("utf-8"),
        }

    except Exception as e:
        logger.exception("Failed to send webhook")

        return {
            "statusCode": 500,
            "body": str(e),
        }
