#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIST_DIR="${ROOT_DIR}/dist"
BUILD_DIR="${ROOT_DIR}/build"

mkdir -p "${DIST_DIR}"
rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

(
  cd "${ROOT_DIR}/enforcement_lambda"
  zip -qr "${DIST_DIR}/enforcement-lambda.zip" .
)

python3 -m pip install \
  --quiet \
  --target "${BUILD_DIR}/authorizer-lambda" \
  -r "${ROOT_DIR}/authorizer_lambda/requirements.txt"

cp "${ROOT_DIR}/authorizer_lambda/"*.py "${BUILD_DIR}/authorizer-lambda/"

(
  cd "${BUILD_DIR}/authorizer-lambda"
  zip -qr "${DIST_DIR}/authorizer-lambda.zip" .
)

(
  cd "${ROOT_DIR}/scp-detector"
  zip -qr "${DIST_DIR}/scp-detector-lambda.zip" .
)

printf 'Created %s\n' "${DIST_DIR}/enforcement-lambda.zip"
printf 'Created %s\n' "${DIST_DIR}/authorizer-lambda.zip"
printf 'Created %s\n' "${DIST_DIR}/scp-detector-lambda.zip"
