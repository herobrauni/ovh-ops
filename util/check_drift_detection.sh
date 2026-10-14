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
overridden_disabled=0
redundant=0

for file in $files; do
    total=$((total + 1))
    if grep -q "driftDetection:" "$file"; then
        if grep -A 1 "driftDetection:" "$file" | grep -q "mode: disabled"; then
            echo "⚠️  $file explicitly disables drift detection"
            overridden_disabled=$((overridden_disabled + 1))
        elif grep -A 1 "driftDetection:" "$file" | grep -q "mode: enabled"; then
            echo "ℹ️  $file has redundant explicit drift detection"
            redundant=$((redundant + 1))
        else
            echo "❓ $file has custom drift detection configuration"
        fi
    else
        inherited=$((inherited + 1))
    fi
done

echo ""
echo "Summary:"
echo "-------"
echo "Global drift detection: Enabled ($ks_file)"
echo "Total HelmRelease files: $total"
echo "Files inheriting global drift detection: $inherited"
if [ "$overridden_disabled" -gt 0 ]; then
    echo "Files with drift detection disabled: $overridden_disabled"
fi
if [ "$redundant" -gt 0 ]; then
    echo "Files with redundant explicit drift detection: $redundant"
fi

if [ "$inherited" -eq "$total" ]; then
    echo "✅ 100% of HelmReleases are covered by global drift detection"
fi
