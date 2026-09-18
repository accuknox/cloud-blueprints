#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 2 || $# -gt 7 ]]; then
  printf 'Usage: %s <bucket> <queue-url> [prefix] [max-files] [files-per-message] [queue-region] [bucket-region]\n' "$0" >&2
  exit 2
fi

BUCKET="$1"
QUEUE_URL="$2"
PREFIX="${3:-AWSLogs/}"
MAX_FILES="${4:-100}"
FILES_PER_MESSAGE="${5:-1}"
QUEUE_REGION="${6:-us-east-2}"
BUCKET_REGION="${7:-${QUEUE_REGION}}"

if ! [[ "${MAX_FILES}" =~ ^[0-9]+$ ]] || (( MAX_FILES < 1 || MAX_FILES > 1000 )); then
  printf 'max-files must be between 1 and 1000\n' >&2
  exit 2
fi

if ! [[ "${FILES_PER_MESSAGE}" =~ ^[0-9]+$ ]] || (( FILES_PER_MESSAGE < 1 || FILES_PER_MESSAGE > 10 )); then
  printf 'files-per-message must be between 1 and 10\n' >&2
  exit 2
fi

OBJECT_KEYS="$(aws s3api list-objects-v2 \
  --region "${BUCKET_REGION}" \
  --bucket "${BUCKET}" \
  --prefix "${PREFIX}" \
  --max-items "${MAX_FILES}" \
  --query 'Contents[?contains(Key, `/CloudTrail/`) && ends_with(Key, `.json.gz`)].Key' \
  --output json)"

FILE_COUNT="$(jq 'length' <<<"${OBJECT_KEYS}")"
if (( FILE_COUNT == 0 )); then
  printf 'No CloudTrail .json.gz files found under s3://%s/%s\n' "${BUCKET}" "${PREFIX}" >&2
  exit 1
fi

MESSAGE_ENTRIES="$(jq -c \
  --arg bucket "${BUCKET}" \
  --argjson size "${FILES_PER_MESSAGE}" \
  '. as $keys |
  [range(0; ($keys | length); $size) as $start |
    {
      Id: ("message-" + (($start / $size | floor) | tostring)),
      MessageBody: ({s3Bucket: $bucket, s3ObjectKey: $keys[$start:$start + $size]} | tojson)
    }
  ]' <<<"${OBJECT_KEYS}")"

MESSAGE_COUNT="$(jq 'length' <<<"${MESSAGE_ENTRIES}")"
SENT_COUNT=0
while IFS= read -r SQS_BATCH; do
  SEND_RESULT="$(aws sqs send-message-batch \
    --region "${QUEUE_REGION}" \
    --queue-url "${QUEUE_URL}" \
    --entries "${SQS_BATCH}" \
    --output json)"
  FAILED_COUNT="$(jq '.Failed | length' <<<"${SEND_RESULT}")"
  if (( FAILED_COUNT > 0 )); then
    jq '.Failed' <<<"${SEND_RESULT}" >&2
    exit 1
  fi
  SENT_COUNT=$((SENT_COUNT + $(jq '.Successful | length' <<<"${SEND_RESULT}")))
done < <(jq -c '[range(0; length; 10) as $start | .[$start:$start + 10]][]' <<<"${MESSAGE_ENTRIES}")

if (( SENT_COUNT != MESSAGE_COUNT )); then
  printf 'Expected to send %s messages but sent %s.\n' "${MESSAGE_COUNT}" "${SENT_COUNT}" >&2
  exit 1
fi

printf 'Queued %s files in %s SQS messages.\n' "${FILE_COUNT}" "${MESSAGE_COUNT}"
