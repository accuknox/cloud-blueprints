#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUTPUT_FILE="${1:-${SCRIPT_DIR}/scp-s3-poc-lambda.zip}"

(
  cd "${SCRIPT_DIR}"
  zip -q -j "${OUTPUT_FILE}" lambda_function.py
)

printf 'Created %s\n' "${OUTPUT_FILE}"
