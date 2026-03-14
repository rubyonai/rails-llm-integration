#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$PROJECT_DIR/build"
OUTPUT_FILE="$BUILD_DIR/rails-llm-integration.skill"

# Create build directory
mkdir -p "$BUILD_DIR"

# Remove old build if exists
rm -f "$OUTPUT_FILE"

# Zip the skill, excluding build artifacts and junk files
cd "$PROJECT_DIR"
zip -r "$OUTPUT_FILE" . \
  -x ".git/*" \
  -x "build/*" \
  -x ".planning/*" \
  -x ".claude/*" \
  -x "**/.DS_Store" \
  -x ".DS_Store"

echo "Built: $OUTPUT_FILE"
