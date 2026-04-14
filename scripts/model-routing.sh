#!/usr/bin/env bash
# model-routing.sh — thin shell wrapper around model_routing.py
#
# Resolves the appropriate Claude model for a task context using the
# 6-step resolution chain defined in config/model-routing.toml.
#
# Usage: scripts/model-routing.sh [OPTIONS]
#   Passes all arguments through to model_routing.py.
#
# Quick reference:
#   --override MODEL   Step 1: use this exact model
#   --priority P0      Step 2: P0 bead → deep/Opus
#   --type TYPE        Step 3: bead type routing
#   --files N          Step 4: complexity (files changed)
#   --deps N           Step 4: complexity (dependency count)
#   --role ROLE        Step 5: role-default routing
#   --json             Output JSON {model, tier, reason}
#
# VICTORY_MODEL_OVERRIDE env var is also honored (step 1).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

exec python3 "${SCRIPT_DIR}/model_routing.py" "$@"
