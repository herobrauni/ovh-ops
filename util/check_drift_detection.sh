#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

ks_file="kubernetes/flux/cluster/ks.yaml"

echo "Checking HelmRelease drift detection configuration..."
echo ""

if [ ! -f "$ks_file" ]; then
    echo "❌ Cluster Kustomization file not found: $ks_file"
    exit 1
fi

if grep -A 2 "driftDetection:" "$ks_file" | grep -q "mode: enabled"; then
    echo "✅ Global drift detection is enabled in $ks_file (cluster-apps patch)"
else
    echo "❌ Global drift detection is NOT enabled in $ks_file"
    exit 1
fi

echo ""

files=$(find kubernetes/apps -name "helmrelease.yaml" | sort)
total=0
inherited=0
redundant=0
custom=0

for file in $files; do
    total=$((total + 1))
    if ! grep -q "driftDetection:" "$file"; then
        inherited=$((inherited + 1))
        continue
    fi
    echo "ℹ️  $file declares driftDetection explicitly"
    if grep -A 1 "driftDetection:" "$file" | grep -q "mode: enabled"; then
        redundant=$((redundant + 1))
    elif grep -A 1 "driftDetection:" "$file" | grep -q "mode: disabled"; then
        # NOTE: does NOT override the cluster-apps patch — Kustomization patches are applied to the
        # build output, so the global default wins. An app cannot opt out this way.
        echo "⚠️  $file sets mode: disabled, which the global patch overrides"
        custom=$((custom + 1))
    else
        custom=$((custom + 1))
    fi
done

echo ""
echo "Summary:"
echo "-------"
echo "Global drift detection: enabled ($ks_file)"
echo "Total HelmRelease files: $total"
echo "Files inheriting global drift detection: $inherited"
echo "Files carrying redundant explicit driftDetection: $redundant"

if [ "$inherited" -eq "$total" ]; then
    echo "✅ 100% of HelmReleases are covered by global drift detection"
else
    echo "❌ $((total - inherited)) file(s) still declare driftDetection explicitly — remove the blocks"
    exit 1
fi

