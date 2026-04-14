#!/usr/bin/env python3
"""
model_routing.py — Victory pack model routing resolver

Applies a 6-step resolution chain to select the appropriate Claude model:
  1. Explicit override   (--override / VICTORY_MODEL_OVERRIDE)
  2. P0 priority         (priority == "P0" → deep tier)
  3. Bead type           (routing.tasks mapping)
  4. Complexity heuristic (files > threshold OR deps > threshold → deep tier)
  5. Role default        (routing.roles mapping)
  6. Sonnet fallback     (defaults.tier)

Usage:
  scripts/model_routing.py [OPTIONS]

  --config PATH       Path to model-routing.toml (default: config/model-routing.toml
                      relative to this script's parent directory)
  --override MODEL    Explicit model ID (step 1)
  --priority LEVEL    Bead priority: P0, P1, P2 (step 2)
  --type TYPE         Bead/task type: triage, implementation, etc. (step 3)
  --files N           Number of files changed (step 4)
  --deps N            Number of dependencies (step 4)
  --role ROLE         Agent role: polecat, witness, mayor, etc. (step 5)
  --json              Output JSON with model, tier, and resolution reason
  --help              Show this message and exit

Exit codes:
  0   Model resolved successfully
  1   Config file not found
  2   Invalid arguments
"""

import argparse
import json
import os
import sys
import tomllib
from pathlib import Path


def find_config(script_path: Path) -> Path:
    """Find config/model-routing.toml relative to the pack root (script's parent dir)."""
    return script_path.parent.parent / "config" / "model-routing.toml"


def load_config(config_path: Path) -> dict:
    with open(config_path, "rb") as f:
        return tomllib.load(f)


def resolve_model(cfg: dict, args: argparse.Namespace) -> tuple[str, str, str]:
    """
    Apply the 6-step resolution chain.

    Returns (model_id, tier_name, reason).
    """
    tiers = cfg.get("tiers", {})

    def tier_to_model(tier: str) -> str:
        return tiers.get(tier, {}).get("model", tiers.get("medium", {}).get("model", "claude-sonnet-4-6"))

    # Step 1: Explicit override
    override = args.override or os.environ.get("VICTORY_MODEL_OVERRIDE", "")
    if override:
        return override, "override", f"explicit override: {override}"

    # Step 2: P0 priority → deep
    if args.priority and args.priority.upper() == "P0":
        tier = "deep"
        return tier_to_model(tier), tier, "P0 priority → deep tier"

    routing = cfg.get("routing", {})

    # Step 3: Bead type mapping
    if args.type:
        task_routes = routing.get("tasks", {})
        tier = task_routes.get(args.type)
        if tier:
            return tier_to_model(tier), tier, f"bead type '{args.type}' → {tier} tier"

    # Step 4: Complexity heuristic (files > threshold OR deps > threshold)
    complexity = routing.get("complexity", {})
    file_threshold = complexity.get("file_threshold", 5)
    dep_threshold = complexity.get("dep_threshold", 3)
    escalate_to = complexity.get("escalate_to", "deep")

    files = args.files if args.files is not None else 0
    deps = args.deps if args.deps is not None else 0

    if files > file_threshold or deps > dep_threshold:
        tier = escalate_to
        reason_parts = []
        if files > file_threshold:
            reason_parts.append(f"files {files} > {file_threshold}")
        if deps > dep_threshold:
            reason_parts.append(f"deps {deps} > {dep_threshold}")
        return tier_to_model(tier), tier, f"complexity heuristic ({', '.join(reason_parts)}) → {tier} tier"

    # Step 5: Role default
    if args.role:
        role_routes = routing.get("roles", {})
        tier = role_routes.get(args.role)
        if tier:
            return tier_to_model(tier), tier, f"role '{args.role}' → {tier} tier"

    # Step 6: Sonnet fallback (defaults.tier)
    defaults = cfg.get("defaults", {})
    fallback_tier = defaults.get("tier", "medium")
    return tier_to_model(fallback_tier), fallback_tier, f"default fallback → {fallback_tier} tier"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Resolve the Claude model for a given task context",
        add_help=True,
    )
    parser.add_argument("--config", help="Path to model-routing.toml")
    parser.add_argument("--override", help="Explicit model ID (step 1)")
    parser.add_argument("--priority", help="Bead priority: P0, P1, P2 (step 2)")
    parser.add_argument("--type", help="Bead/task type: triage, implementation, etc. (step 3)")
    parser.add_argument("--files", type=int, help="Number of files changed (step 4)")
    parser.add_argument("--deps", type=int, help="Number of dependencies (step 4)")
    parser.add_argument("--role", help="Agent role: polecat, witness, mayor, etc. (step 5)")
    parser.add_argument("--json", action="store_true", help="Output JSON")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    script_path = Path(__file__).resolve()

    if args.config:
        config_path = Path(args.config)
    else:
        config_path = find_config(script_path)

    if not config_path.exists():
        print(f"error: config file not found: {config_path}", file=sys.stderr)
        return 1

    try:
        cfg = load_config(config_path)
    except Exception as e:
        print(f"error: failed to parse config: {e}", file=sys.stderr)
        return 1

    model, tier, reason = resolve_model(cfg, args)

    if args.json:
        print(json.dumps({"model": model, "tier": tier, "reason": reason}))
    else:
        print(model)

    return 0


if __name__ == "__main__":
    sys.exit(main())
