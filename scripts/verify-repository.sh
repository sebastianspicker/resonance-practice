#!/usr/bin/env bash
# Run pure repository checks shared by local and GitHub CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Verifying Node runtime..."
node ./scripts/check-node-version.mjs

echo "Validating canonical v1 API contract..."
node ./scripts/validate-v1-contract.mjs
node ./scripts/generate-v1-contract-projection.mjs

echo "Checking iOS source layering..."
node ./scripts/check-ios-layers.mjs --self-test
node ./scripts/check-ios-layers.mjs

echo "Validating demo fixture..."
node ./scripts/demo/validate-fixture.mjs

echo "Validating static Pages demo..."
node ./scripts/demo/validate-static-site.mjs

echo "Validating public documentation..."
node ./scripts/validate-public-docs.mjs

echo "Running secret scan..."
./scripts/secret-scan.sh

echo "Checking committed build artifacts..."
./scripts/check-no-build-artifacts.sh
