#!/usr/bin/env bash
# Creates the settings files from their examples:
#
#   common.tfvars.example                   -> common.tfvars
#   stacks/<stack>/terraform.tfvars.example -> stacks/<stack>/terraform.tfvars   (every stack)
#
# Existing files are kept (they may hold your edits) unless you pass --force,
# which overwrites them after saving a .bak copy. The created files are
# git-ignored. Edit them afterwards; the .example files are never read by Terraform.
#
# Usage:
#   ./scripts/init-tfvars.sh            create the missing files
#   ./scripts/init-tfvars.sh --force    recreate all of them (old ones saved as *.bak)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FORCE=false
case "${1:-}" in
  "") ;;
  --force) FORCE=true ;;
  *) echo "usage: $0 [--force]"; exit 1 ;;
esac

created=0 kept=0 replaced=0

copy() { # <example> <target>
  local src="$1" dst="$2" rel="${2#"$ROOT"/}"
  if [[ -f "$dst" ]] && ! $FORCE; then
    echo "  kept      $rel (already exists; --force to recreate)"
    kept=$((kept + 1))
  elif [[ -f "$dst" ]]; then
    cp "$dst" "$dst.bak"
    cp "$src" "$dst"
    echo "  replaced  $rel (old one saved as ${rel}.bak)"
    replaced=$((replaced + 1))
  else
    cp "$src" "$dst"
    echo "  created   $rel"
    created=$((created + 1))
  fi
}

echo "Settings files:"
copy "$ROOT/common.tfvars.example" "$ROOT/common.tfvars"
for example in "$ROOT"/stacks/*/terraform.tfvars.example; do
  copy "$example" "${example%.example}"
done

echo "Done: $created created, $replaced replaced, $kept kept."
echo "Next: edit common.tfvars (project, creator, regions, deploy_origin / deploy_cache, AZs)."
