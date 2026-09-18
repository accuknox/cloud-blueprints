import gzip
import importlib.util
import io
import json
import os
import pathlib
import unittest
from unittest import mock


MODULE_PATH = pathlib.Path(__file__).with_name("lambda_function.py")
SPEC = importlib.util.spec_from_file_location("scp_s3_poc_lambda", MODULE_PATH)
lambda_function = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(lambda_function)


class FakeBody:
    def __init__(self, value):
        self.value = value

    def read(self):
        return self.value


class FakeS3:
    def __init__(self, document):
        raw = json.dumps(document).encode("utf-8")
        buffer = io.BytesIO()
        with gzip.GzipFile(fileobj=buffer, mode="wb") as stream:
            stream.write(raw)
        self.value = buffer.getvalue()

    def get_object(self, **_kwargs):
        return {"Body": FakeBody(self.value), "ContentLength": len(self.value)}


class LambdaFunctionTests(unittest.TestCase):
    def setUp(self):
        self.environment = mock.patch.dict(
            os.environ,
            {
                "DRY_RUN": "true",
                "DEDUP_TABLE_NAME": "dedup-table",
                "DEDUP_RETENTION_DAYS": "7",
            },
            clear=False,
        )
        self.environment.start()

    def tearDown(self):
        self.environment.stop()

    def test_extracts_raw_cloudtrail_sns_notification(self):
        body = json.dumps(
            {"s3Bucket": "logs", "s3ObjectKey": ["AWSLogs/a.json.gz"]}
        )
        self.assertEqual(
            lambda_function.extract_s3_objects(body),
            [("logs", "AWSLogs/a.json.gz")],
        )

    def test_extracts_wrapped_sns_notification(self):
        cloudtrail_message = json.dumps(
            {"s3Bucket": "logs", "s3ObjectKey": ["AWSLogs/a.json.gz"]}
        )
        body = json.dumps({"Type": "Notification", "Message": cloudtrail_message})
        self.assertEqual(
            lambda_function.extract_s3_objects(body),
            [("logs", "AWSLogs/a.json.gz")],
        )

    def test_extracts_direct_s3_notification_and_decodes_key(self):
        body = json.dumps(
            {
                "Records": [
                    {
                        "eventSource": "aws:s3",
                        "s3": {
                            "bucket": {"name": "logs"},
                            "object": {"key": "AWSLogs/a%2Bb.json.gz"},
                        },
                    }
                ]
            }
        )
        self.assertEqual(
            lambda_function.extract_s3_objects(body),
            [("logs", "AWSLogs/a+b.json.gz")],
        )

    def test_scp_filter_requires_authorization_error_and_scp_message(self):
        self.assertTrue(
            lambda_function.is_scp_denial(
                {
                    "errorCode": "AccessDenied",
                    "errorMessage": "explicit deny in a service control policy",
                }
            )
        )
        self.assertFalse(
            lambda_function.is_scp_denial(
                {
                    "errorCode": "AccessDenied",
                    "errorMessage": "no identity-based policy allows the action",
                }
            )
        )
        self.assertFalse(
            lambda_function.is_scp_denial(
                {
                    "errorCode": "ValidationException",
                    "errorMessage": "service control policy is malformed",
                }
            )
        )

    def test_processes_file_and_counts_scp_match_in_dry_run(self):
        document = {
            "Records": [
                {
                    "eventID": "event-1",
                    "eventTime": "2026-09-16T00:00:00Z",
                    "errorCode": "AccessDenied",
                    "errorMessage": "explicit deny in a service control policy",
                },
                {
                    "eventID": "event-2",
                    "errorCode": "AccessDenied",
                    "errorMessage": "no identity-based policy allows the action",
                },
                {"eventID": "event-3", "eventName": "ListBuckets"},
            ]
        }
        lambda_function._s3_client = FakeS3(document)

        with mock.patch.object(lambda_function, "claim_event", return_value=True), mock.patch.object(
            lambda_function, "complete_event"
        ) as complete:
            metrics = lambda_function.process_log_file(
                "logs", "AWSLogs/123/CloudTrail/us-east-2/file.json.gz"
            )

        self.assertEqual(metrics["CloudTrailRecordsProcessed"], 3)
        self.assertEqual(metrics["ErrorRecords"], 2)
        self.assertEqual(metrics["AuthorizationFailures"], 2)
        self.assertEqual(metrics["ScpMatches"], 1)
        self.assertEqual(metrics["WebhookSuccesses"], 0)
        complete.assert_called_once_with("event-1")

    def test_lambda_reports_only_failed_sqs_messages(self):
        event = {
            "Records": [
                {"messageId": "good", "body": json.dumps({"s3Bucket": "b", "s3ObjectKey": []})},
                {"messageId": "bad", "body": "not-json"},
            ]
        }
        context = type("Context", (), {"function_name": "test-function"})()
        with mock.patch.object(lambda_function, "emit_metrics"):
            result = lambda_function.lambda_handler(event, context)
        self.assertEqual(result, {"batchItemFailures": [{"itemIdentifier": "bad"}]})


if __name__ == "__main__":
    unittest.main()
