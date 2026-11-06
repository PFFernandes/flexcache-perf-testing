#!/usr/bin/env bash
# Thin wrapper so every stack is run the same way (run it on your Mac).
#
#   ./tf.sh <stack> <terraform command> [extra args]
#
# Examples:
#   ./tf.sh 01-landing-zone init
#   ./tf.sh 01-landing-zone plan
#   ./tf.sh 02-fsxn apply -var deploy_cache=false
#   ./tf.sh 03-flexcache destroy
#   ./tf.sh 02-fsxn output
#
# What it adds on top of plain terraform:
#   - plan/apply/destroy/import/console/refresh: passes ../../common.tfvars
#   - the stack's own terraform.tfvars is auto-loaded by terraform itself
#   - state stays local: stacks/<stack>/terraform.tfstate
#
# Set TF_BIN=tofu to use OpenTofu instead of Terraform.
set -euo pipefail

TF="${TF_BIN:-terraform}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() { echo "usage: ./tf.sh <stack> <command> [args]"; echo "stacks:"; ls -1 "$ROOT/stacks"; exit 1; }

STACK="${1:-}"; CMD="${2:-}"
[[ -z "$STACK" || -z "$CMD" ]] && usage
shift 2

DIR="$ROOT/stacks/$STACK"
[[ -d "$DIR" ]] || { echo "No such stack: $STACK"; usage; }

case "$CMD" in
  plan|apply|destroy|import|console|refresh)
    [[ -f "$ROOT/common.tfvars" ]] || { echo "Missing common.tfvars - copy common.tfvars.example and edit it."; exit 1; }
    echo "Settings loaded for $STACK:"
    echo "  $ROOT/common.tfvars"
    grep -E '^[[:space:]]*(origin_region|cache_region)[[:space:]]*=' "$ROOT/common.tfvars" | sed 's/^/      /'
    if [[ -f "$DIR/terraform.tfvars" ]]; then
      echo "  $DIR/terraform.tfvars"
      grep -E '^[[:space:]]*[a-z_]+[[:space:]]*=' "$DIR/terraform.tfvars" | sed 's/^/      /'
    elif [[ -f "$DIR/terraform.tfvars.example" ]]; then
      echo "  (no stacks/$STACK/terraform.tfvars - defaults are used; the .example file is NOT read)"
    fi
    exec "$TF" -chdir="$DIR" "$CMD" -var-file="$ROOT/common.tfvars" "$@"
    ;;
  *)
    exec "$TF" -chdir="$DIR" "$CMD" "$@"
    ;;
esac
