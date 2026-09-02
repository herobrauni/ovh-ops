#!/usr/bin/env bash
#
# Verify that vendored upstream operator manifests stay in sync with the
# operator component images that Renovate bumps in the companion images.yaml.
#
# Background: KubeVirt and CDI are installed from vendored upstream
# `*-operator.yaml` manifests (RBAC + CRD + Deployment) whose component images
# are overridden afterwards via digest-pinned env vars (images.yaml). Renovate
# bumps ONLY the images.yaml references. If a new upstream minor introduces
# permissions the vendored ClusterRole does not hold (e.g. KubeVirt v1.9.0 and
# the `plugin.kubevirt.io` API group), the API server's RBAC escalation guard
# rejects the operator's own RBAC update and the upgrade stalls with
# `DeploymentFailed` until the vendored manifest is re-vendored from the
# matching release.
#
# This check fails whenever the version in a vendored header differs from the
# version of the operator image env vars, forcing the re-vendor to happen in
# the same change as the image bump.

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

failures=0

# operator_name|vendored_manifest|images_file|env_var_name
checks=(
    "kubevirt|kubernetes/apps/kubevirt/kubevirt/operator/operator.yaml|kubernetes/apps/kubevirt/kubevirt/operator/images.yaml|VIRT_OPERATOR_IMAGE"
    "cdi|kubernetes/apps/cdi/cdi/operator/operator.yaml|kubernetes/apps/cdi/cdi/operator/images.yaml|CONTROLLER_IMAGE"
)

for entry in "${checks[@]}"; do
    IFS='|' read -r name vendored images env_var <<<"$entry"

    # Header format: "# Vendored from the <Product> vX.Y.Z release; ..."
    # — accept an optional product name before the version.
    vendored_version=$(sed -n 's/^# Vendored from the \([A-Za-z ]*\)\?\(v[0-9][0-9.]*\) release.*/\2/p' "$vendored" | head -1)
    if [[ -z "$vendored_version" ]]; then
        echo "❌ ${name}: no '# Vendored from the <version> release' header found in ${vendored}"
        failures=$((failures + 1))
        continue
    fi

    images_version=$(sed -n "s/^.*name: ${env_var}$/&/p" "$images" >/dev/null; awk -v env_var="$env_var" '
        $0 ~ "- name: " env_var "$" { found = 1; next }
        found == 1 && $0 ~ /^ *value: / {
            sub(/^ *value: /, "")
            print
            exit
        }
    ' "$images" | sed -n 's/.*:\(v[0-9][0-9.]*\)@.*/\1/p')
    if [[ -z "$images_version" ]]; then
        echo "❌ ${name}: could not extract version from ${env_var} in ${images}"
        failures=$((failures + 1))
        continue
    fi

    if [[ "$vendored_version" == "$images_version" ]]; then
        echo "✅ ${name}: vendored manifest and operator images both ${vendored_version}"
    else
        echo "❌ ${name}: vendored manifest is ${vendored_version} but ${env_var} in images.yaml is ${images_version}"
        echo "   Re-vendor ${vendored} from the ${images_version} upstream release"
        echo "   (drop the leading Namespace doc, keep the vendored-from header,"
        echo "   format with yamlfmt and the repo .yamlfmt.yaml), then commit"
        echo "   the re-vendored manifest together with the image bump."
        failures=$((failures + 1))
    fi
done

if ((failures > 0)); then
    echo ""
    echo "Vendored operator sync check failed with ${failures} issue(s)." >&2
    exit 1
fi

echo ""
echo "Vendored operator manifests are in sync with their images."
