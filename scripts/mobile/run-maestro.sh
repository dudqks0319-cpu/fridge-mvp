#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

maestro test "$ROOT_DIR/fridge_mobile_app/maestro/home_smoke.yaml"
maestro test "$ROOT_DIR/fridge_mobile_app/maestro/recipe_smoke.yaml"

echo "Maestro smoke tests completed."
