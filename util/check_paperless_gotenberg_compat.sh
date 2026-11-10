#!/usr/bin/env bash
#
# Guards the paperless <-> gotenberg pair.
#
# The paperless image ships a pinned gotenberg-client, and that client has a
# hardcoded picture of gotenberg's HTTP API (routes and form fields). Renovate
# bumps both images independently, so a gotenberg major can land in this repo
# while the client inside the deployed paperless image still speaks the old
# API. That happened with gotenberg 9: it moved /forms/pdfengines/* to
# /forms/pdf/* and replaced the pdfa/pdfua form fields, which answers 400/404
# on every conversion.
#
# So: whenever gotenberg crosses into a breaking major, prove the client that
# paperless actually ships does not use anything that major removed.
#
# Inputs (all resolvable offline from public sources):
#   paperless tag       kubernetes/apps/selfhosted/paperless/app/helmrelease.yaml
#   gotenberg tag       same file
#   client version      paperless-ngx v<tag>/uv.lock -- the lockfile the image was built from
#   client API surface  gotenberg-client <version> wheel from PyPI
#
# Matrix: https://gotenberg.dev/docs/getting-started/upgrade

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

helmrelease="kubernetes/apps/selfhosted/paperless/app/helmrelease.yaml"

# First gotenberg major that carries the breaking changes listed below.
breaking_major=9
# Substrings that only appear in a client that still speaks the pre-9 API.
# Extend the table (and bump breaking_major) when the next breaking major lands.
removed_patterns=(
  "/forms/pdfengines"
  '"pdfa"'
  '"pdfua"'
  "splitUnify"
  "singlePageSheets"
  "exportBookmarks"
  "generateTaggedPdf"
  "nativePageRanges"
  "rotateAngle"
)

paperless_tag=$(mise exec -- yq -r '.spec.values.controllers.paperless.containers.app.image.tag' "$helmrelease")
gotenberg_tag=$(mise exec -- yq -r '.spec.values.controllers.gotenberg.containers.app.image.tag' "$helmrelease")

paperless_version=${paperless_tag%%@*}
gotenberg_version=${gotenberg_tag%%@*}
gotenberg_major=${gotenberg_version%%.*}

if (( gotenberg_major < breaking_major )); then
  echo "OK: gotenberg ${gotenberg_version} is below the breaking major ${breaking_major}.x (paperless ${paperless_version})"
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

lock_url="https://raw.githubusercontent.com/paperless-ngx/paperless-ngx/v${paperless_version}/uv.lock"
if ! curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/uv.lock" "$lock_url"; then
  echo "ERROR: cannot fetch ${lock_url}" >&2
  echo "       paperless v${paperless_version} has no reachable lockfile, so the" >&2
  echo "       gotenberg ${gotenberg_version} compatibility cannot be verified." >&2
  echo "       Check the paperless tag (upstream release tag must be v${paperless_version})." >&2
  exit 1
fi

client_version=$(grep -A1 '^name = "gotenberg-client"$' "$tmp/uv.lock" \
  | sed -n 's/^version = "\(.*\)"/\1/p' | head -1 || true)
if [[ -z $client_version ]]; then
  echo "ERROR: gotenberg-client not found in the lockfile of paperless v${paperless_version}" >&2
  echo "       The guard assumes paperless uses gotenberg; update util/$(basename "${BASH_SOURCE[0]}") if that changed." >&2
  exit 1
fi

wheel_url=$(curl -fsSL --retry 3 --retry-delay 2 "https://pypi.org/pypi/gotenberg-client/${client_version}/json" \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(next(u["url"] for u in d["urls"] if u["filename"].endswith(".whl")))')
curl -fsSL --retry 3 --retry-delay 2 -o "$tmp/client.whl" "$wheel_url"
python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])' "$tmp/client.whl" "$tmp/src"

matches=$(grep -rn -F -f <(printf '%s\n' "${removed_patterns[@]}") --include='*.py' "$tmp/src" || true)

if [[ -n $matches ]]; then
  echo "ERROR: gotenberg ${gotenberg_version} removed API that paperless ${paperless_version} still calls." >&2
  echo "       gotenberg-client ${client_version} (shipped in that paperless image) uses:" >&2
  printf '%s\n' "$matches" | sed "s|^${tmp}/src/||" | head -20 | sed 's/^/         /' >&2
  echo "" >&2
  echo "       Fix: bump paperless to a release whose gotenberg-client speaks the ${breaking_major}.x API," >&2
  echo "       then let renovate re-propose gotenberg ${breaking_major}. Do not ship both independently." >&2
  exit 1
fi

echo "OK: gotenberg ${gotenberg_version} is compatible with gotenberg-client ${client_version} (paperless ${paperless_version})"
