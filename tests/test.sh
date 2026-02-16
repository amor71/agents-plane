#!/bin/bash
# Agents Plane — Full Test Suite
# Usage: bash tests/test.sh [--unit-only] [--docker-only]
set -e

DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(dirname "$DIR")"

echo ""
echo "═══════════════════════════════════════════"
echo "  🧪 Agents Plane Test Suite"
echo "═══════════════════════════════════════════"
echo ""

UNIT_ONLY=false
DOCKER_ONLY=false
for arg in "$@"; do
  case $arg in
    --unit-only) UNIT_ONLY=true ;;
    --docker-only) DOCKER_ONLY=true ;;
  esac
done

# --- Phase 1: Unit Tests (fast, no Docker) ---
if [ "$DOCKER_ONLY" != "true" ]; then
  echo "━━━ Phase 1: Unit Tests (< 1 second) ━━━"
  echo ""
  node "$DIR/test-startup-script.js"
  echo ""
fi

# --- Phase 2: Docker Integration (slower, tests real install) ---
if [ "$UNIT_ONLY" != "true" ]; then
  echo "━━━ Phase 2: Docker Integration ━━━"
  echo ""
  
  # Check if base image exists
  if ! docker image inspect agents-plane-base > /dev/null 2>&1; then
    echo "📦 Building base image (one-time, ~2 min)..."
    docker build -t agents-plane-base -f "$DIR/docker/Dockerfile.base" "$DIR/docker/"
    echo ""
  fi
  
  echo "🔨 Building test image..."
  docker build -t agents-plane-test -f "$DIR/docker/Dockerfile" "$DIR/docker/"
  echo ""
  
  echo "🏃 Running verification..."
  docker run --rm agents-plane-test
  echo ""
fi

echo "═══════════════════════════════════════════"
echo "  ✅ All tests passed!"
echo "═══════════════════════════════════════════"
