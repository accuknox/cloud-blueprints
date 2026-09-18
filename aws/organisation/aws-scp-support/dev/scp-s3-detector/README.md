# SCP alerts from CloudTrail S3 logs — PoC

This PoC measures whether centralized CloudTrail log processing is a practical
replacement for the regional EventBridge forwarding stacks.

The standalone replay template does not modify or remove an existing
EventBridge path. The integrated organization templates replace the regional
EventBridge forwarders with this centralized path. Both variants default to
`DryRun=true`, so detected SCP events are counted but are not sent to the
platform webhook.

## Flow

Historical replay:

```text
Existing CloudTrail S3 bucket -> replay script -> SQS -> Lambda
                                              -> DynamoDB deduplication
                                              -> CloudWatch metrics
```

Optional live test:

```text
Organization CloudTrail -> S3
                        -> SNS log-delivery notification -> SQS -> Lambda
```

CloudTrail's SNS message only identifies delivered S3 objects. Lambda downloads
and decompresses each object, examines its `Records`, and recognizes an SCP
candidate only when both conditions are true:

- the record is an authorization failure; and
- the error message identifies a service control policy/Organizations policy.

This is intentionally narrower than the existing EventBridge rule, which sends
every event containing an `errorCode`.

## Reliability and cost controls

- SQS batches up to 10 messages per Lambda invocation by default.
- The replay script defaults to one S3 object per message, matching the common
  live notification shape. It can group up to 10 keys when testing throughput.
- Partial batch failure reporting retries only failed SQS messages.
- A dead-letter queue receives messages after five failed receives.
- DynamoDB uses CloudTrail `eventID` to suppress duplicate alerts for seven days.
- Lambda emits volume metrics under `AccuKnox/ScpS3Poc`.

## Observed baseline

Read-only measurement of the retained test bucket on 2026-09-16 found:

- 9,690 CloudTrail objects
- 85,874,001 compressed bytes (about 81.9 MiB)
- object modification times from 2026-09-14 00:00 UTC to
  2026-09-16 05:08 UTC
- about 183 files/hour across that window

This should be treated as a preliminary sizing sample because traffic can vary
by customer, account count, and AWS API activity.

Extrapolated at the same rate, the pipeline would receive about 133,000 log-file
notifications per month. That is below the published monthly free-tier request
allowances for SNS, SQS, and Lambda, if those shared account-level allowances
are still available. Lambda duration, S3 GET requests, DynamoDB writes,
CloudWatch logs/metrics, and the existing CloudTrail/S3 storage remain separate
costs. The live PoC is required to measure Lambda duration and actual batching.

## Historical replay results (2026-09-16)

The standalone stack was deployed in organization account `143825259535` in
`us-east-1`, using the cross-account artifact bucket in `us-east-1`. It read the
retained CloudTrail bucket in `us-east-2`. This cross-Region layout was used
only because the PoC artifact was not readable from the regional `us-east-2`
artifact path; production resources should be colocated.

All tests used `DryRun=true`. No webhook requests were made, every processing
queue message completed, and the dead-letter queue remained empty.

| Replay | Files | Compressed bytes | CloudTrail records | Error records | Authorization failures | Lambda invocations | Billed duration |
|---:|---:|---:|---:|---:|---:|---:|---:|
| Initial batching sample | 10 | 328,315 | 846 | 481 | 355 | 3 | 2,084 ms |
| Throughput sample | 100 | 1,194,266 | 3,837 | 1,460 | 1,065 | 3 | 8,420 ms |
| Larger throughput sample | 1,000 | 6,032,020 | 17,154 | 3,333 | 2,139 | 11 | 58,925 ms |

The replay selections overlap because each run starts at the beginning of the
same S3 prefix. They are separate batching/throughput measurements, not a count
of distinct files across all runs.

None of the sampled historical records had an authorization error message that
explicitly identified a service control policy. The historical replay proved
the S3/SQS/Lambda processing path; the live organization test below separately
proved detection of a real SCP denial.

## Live organization test (2026-09-17)

The integrated templates were deployed to management account `143825259535`.
The update removed the regional SCP alert forwarding StackSet and EventBridge
bus/rules, then added the central SNS topic, SQS processing queue and DLQ,
DynamoDB deduplication table, and SQS-triggered detector Lambda.

A temporary SCP was attached directly to test member account `539247474401`.
It denied only the read-only `ec2:DescribeInstances` action. The denied call was
made in `ap-south-1`, outside the onboarding stack's configured cloud-scanning
regions (`us-east-1,us-east-2`).

| Stage | UTC timestamp | Delay from event |
|---|---:|---:|
| CloudTrail event | 06:21:09 | 0 seconds |
| S3 object written | 06:26:01 | 292 seconds |
| Detector processed object | 06:26:10 | 301 seconds |

The delivered file contained one authorization failure and the detector
reported `ScpMatches=1`, `DuplicateScpEvents=0`, and `WebhookFailures=0`.
The DynamoDB event record reached `COMPLETE`; the Lambda logs had no errors and
the DLQ remained empty. `DryRun=true`, so no platform webhook was called.

After validation, the temporary SCP was detached and deleted. A repeat
`DescribeInstances` call in `ap-south-1` succeeded, confirming cleanup.

## Deploy for historical replay

Package and upload the Lambda artifact:

```bash
./package.sh
aws s3 cp scp-s3-poc-lambda.zip \
  s3://YOUR-ARTIFACT-BUCKET/aws-scp-support/scp-s3-poc-lambda.zip
```

Deploy in the CloudTrail home Region with dry run enabled:

```bash
aws cloudformation deploy \
  --stack-name aws-scp-s3-poc \
  --template-file template.yaml \
  --capabilities CAPABILITY_IAM \
  --parameter-overrides \
    CloudTrailBucketName=YOUR-CLOUDTRAIL-BUCKET \
    LambdaCodeS3Bucket=YOUR-ARTIFACT-BUCKET \
    DryRun=true
```

Get the queue URL from the stack outputs, then replay a small sample:

```bash
./replay-sample.sh \
  YOUR-CLOUDTRAIL-BUCKET \
  YOUR-PROCESSING-QUEUE-URL \
  AWSLogs/ \
  100 \
  1 \
  us-east-2 \
  us-east-2
```

Start with 100 files, verify the Lambda logs and custom metrics, then increase
the sample to 1,000 files. Replaying the same files a second time verifies the
`DuplicateScpEvents` measurement.

Historical replay creates a queue backlog, so Lambda is more likely to receive
full batches than it is during normal low-volume traffic. Use the optional live
SNS test to measure the true invocation rate and end-to-end latency.

## Optional live SNS test

If the organization trail already sends log-delivery notifications to an SNS
topic, pass its ARN as `CloudTrailSnsTopicArn`. The stack creates the SQS
subscription and queue policy.

If the trail has no SNS topic, do not alter it for the first replay test. Adding
one is a separate, reviewed change to the owning CloudTrail stack through its
`SnsTopicName` property.

## Metrics to compare

- `LogFilesProcessed`
- `CompressedBytesProcessed`
- `CloudTrailRecordsProcessed`
- `AuthorizationFailures`
- `ScpMatches`
- `DuplicateScpEvents`
- `WebhookFailures`
- `TimedRecords`, `EventAgeSecondsTotal`, and `MaximumEventAgeSeconds`

The Lambda structured log also includes `MessagesProcessed`, `ErrorRecords`,
and `WebhookSuccesses` without creating additional custom metrics.

Also record Lambda `Invocations`, `Duration`, `Errors`, SQS queue age/depth, and
the end-to-end delay between the CloudTrail record's `eventTime` and processing.

The average record age for a period is `EventAgeSecondsTotal / TimedRecords`.
Enhanced AWS access-denied messages are not available in every authorization
scenario, so compare `AuthorizationFailures` with `ScpMatches` when evaluating
possible false negatives.

DynamoDB prevents duplicates in normal retries. A rare failure after the
webhook succeeds but before the DynamoDB completion update can still cause a
retry, so the alert payload includes CloudTrail `eventID` for downstream
idempotency as well.

When running the standalone template beside an EventBridge path, do not set
`DryRun=false` unless duplicate platform alerts are acceptable for the test
account.
