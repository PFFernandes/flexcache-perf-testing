#!/usr/bin/env bash
# Runs on the OPERATOR MACHINE (Terraform local-exec in modules/11-bench-telemetry).
# The clients have no internet, so the OpenTelemetry Collector package is downloaded here
# once, checked against its published SHA-256, and copied into each results bucket under
#   vendor/otelcol-contrib/<version>/otelcol-contrib_<version>_linux_<arch>.rpm
# A copy that is already in a bucket is not uploaded again.
#
# Environment (set by Terraform):
#   VERSION   e.g. 0.165.0
#   PACKAGES  space-separated <arch>=<sha256>, e.g. "amd64=f045... arm64=c388..."
#   BUCKETS   space-separated <bucket>=<region>
#   CACHE_DIR optional download cache (default ~/.cache/flexcache-bench)
set -euo pipefail

: "${VERSION:?}" "${PACKAGES:?}" "${BUCKETS:?}"
CACHE_DIR="${CACHE_DIR:-$HOME/.cache/flexcache-bench}"
BASE="https://github.com/open-telemetry/opentelemetry-collector-releases/releases/download/v$VERSION"
log() { echo "[bench-stage] $*"; }
sha256() { if command -v sha256sum >/dev/null; then sha256sum "$1" | cut -d' ' -f1; else shasum -a 256 "$1" | cut -d' ' -f1; fi; }

mkdir -p "$CACHE_DIR"
for pkg in $PACKAGES; do
  arch="${pkg%%=*}" want="${pkg#*=}"
  file="otelcol-contrib_${VERSION}_linux_${arch}.rpm"
  local_file="$CACHE_DIR/$file"

  if [[ ! -f "$local_file" || "$(sha256 "$local_file")" != "$want" ]]; then
    log "downloading $file"
    curl -fsSL --retry 3 -o "$local_file.part" "$BASE/$file"
    mv "$local_file.part" "$local_file"
  fi
  got="$(sha256 "$local_file")"
  if [[ "$got" != "$want" ]]; then
    rm -f "$local_file"
    log "SHA-256 mismatch for $file: expected $want, got $got. Not uploading."
    exit 1
  fi
  log "$file verified ($want)"

  for b in $BUCKETS; do
    bucket="${b%%=*}" region="${b#*=}"
    key="vendor/otelcol-contrib/$VERSION/$file"
    if aws s3api head-object --region "$region" --bucket "$bucket" --key "$key" >/dev/null 2>&1; then
      log "s3://$bucket/$key already there"
    else
      aws s3 cp --region "$region" --only-show-errors "$local_file" "s3://$bucket/$key" \
        --metadata "sha256=$want"
      log "uploaded s3://$bucket/$key"
    fi
  done
done
