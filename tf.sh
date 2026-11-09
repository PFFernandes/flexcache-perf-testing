#!/usr/bin/env bash
# Thin wrapper so every stack is run the same way (run it on your Mac).
#
#   ./tf.sh <stack> <terraform command> [extra args]
#
# Examples:
#   ./tf.sh 01-landing-zone init
#   ./tf.sh 01-landing-zone plan          saves the plan in the stack folder
#   ./tf.sh 01-landing-zone apply-plan    applies exactly that saved plan
#   ./tf.sh 02-fsxn apply -var deploy_cache=false
#   ./tf.sh 04-flexcache destroy
#   ./tf.sh 02-fsxn output
#
# What it adds on top of plain terraform:
#   - plan/apply/destroy/import/console/refresh: passes ../../common.tfvars
#   - plan: saves to stacks/<stack>/terraform.tfplan (git-ignored; it can hold secrets)
#   - apply: still makes a fresh plan and asks for confirmation
#   - the stack's own terraform.tfvars is auto-loaded by terraform itself
#   - state stays local: stacks/<stack>/terraform.tfstate
#
# Set TF_BIN=tofu to use OpenTofu instead of Terraform.
set -euo pipefail

TF="${TF_BIN:-terraform}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLAN_FILE="terraform.tfplan"

usage() { echo "usage: ./tf.sh <stack> <command> [args]"; echo "stacks:"; ls -1 "$ROOT/stacks"; exit 1; }

STACK="${1:-}"; CMD="${2:-}"
[[ -z "$STACK" || -z "$CMD" ]] && usage
shift 2

DIR="$ROOT/stacks/$STACK"
[[ -d "$DIR" ]] || { echo "No such stack: $STACK"; usage; }

case "$CMD" in
  apply-plan)
    [[ -f "$DIR/$PLAN_FILE" ]] || { echo "No saved plan for $STACK. Run: ./tf.sh $STACK plan"; exit 1; }
    "$TF" -chdir="$DIR" show "$PLAN_FILE"
    read -r -p "Apply this saved plan? Only 'yes' is accepted: " answer
    [[ "$answer" == "yes" ]] || { echo "Cancelled."; exit 0; }
    # A saved plan already holds its variables, so -var-file must not be passed here.
    "$TF" -chdir="$DIR" apply "$@" "$PLAN_FILE"
    rm -f "$DIR/$PLAN_FILE"
    ;;
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
    if [[ "$CMD" == "plan" && " $* " != *" -out="* ]]; then
      "$TF" -chdir="$DIR" plan -var-file="$ROOT/common.tfvars" -out="$PLAN_FILE" "$@"
      echo "To apply exactly this plan: ./tf.sh $STACK apply-plan"
      exit 0
    fi
    exec "$TF" -chdir="$DIR" "$CMD" -var-file="$ROOT/common.tfvars" "$@"
    ;;
  *)
    exec "$TF" -chdir="$DIR" "$CMD" "$@"
    ;;
esac
