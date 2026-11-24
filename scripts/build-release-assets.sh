#!/bin/bash
# Builds the release assets: install.sh, install.ps1, uninstall.sh, and uninstall.ps1 with the
# ref they download from pinned to a tag, plus SHA256SUMS for the four files.
#
# Usage: scripts/build-release-assets.sh <tag> <output folder>
#
# A pinned installer downloads its payload from the tagged tree, and a pinned uninstaller
# downloads the tagged installer, so a later push to main can neither change nor mix what a
# release installs. The build stops, leaving the output folder untouched, when a pin does not
# apply, which happens when an installer changes how it names the ref it downloads from.

set -euo pipefail

ASSETS=(install.sh install.ps1 uninstall.sh uninstall.ps1)
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A reference to main in a URL path or in a quoted or assigned value, not the word in prose.
MAIN_REF_PATTERN="[-/\"'=]main([^[:alnum:]_.-]|\$)"
STAGING_DIR=""

die() {
    echo "Error: $*" >&2
    exit 1
}

pin_asset() {
    local tag="$1" name="$2"
    sed -e "s|raw\.githubusercontent\.com/fco3lho/unlazier/main|raw.githubusercontent.com/fco3lho/unlazier/$tag|g" \
        -e "s|^BRANCH=\"main\"\$|BRANCH=\"$tag\"|" \
        "$REPO_DIR/$name" > "$STAGING_DIR/$name"
    if cmp -s "$REPO_DIR/$name" "$STAGING_DIR/$name"; then
        die "no pin applied to $name"
    fi
    if grep -nE "$MAIN_REF_PATTERN" "$STAGING_DIR/$name" >&2; then
        die "$name still refers to main on the lines above"
    fi
}

# macOS ships shasum instead of sha256sum; both print the same format.
print_sha256_sums() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$@"
    else
        shasum -a 256 "$@"
    fi
}

main() {
    [ "$#" -eq 2 ] || die "usage: $0 <tag> <output folder>"
    local tag="$1" output_dir="$2" name
    # The tag is written into URLs, sed replacements, and a quoted shell assignment.
    [[ "$tag" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "invalid tag: $tag"

    STAGING_DIR="$(mktemp -d)"
    trap 'rm -rf "$STAGING_DIR"' EXIT
    for name in "${ASSETS[@]}"; do
        pin_asset "$tag" "$name"
    done
    (cd "$STAGING_DIR" && print_sha256_sums "${ASSETS[@]}") > "$STAGING_DIR/SHA256SUMS"

    mkdir -p "$output_dir"
    mv "$STAGING_DIR"/* "$output_dir/"
    echo "Built ${ASSETS[*]} and SHA256SUMS for $tag in $output_dir"
}

main "$@"
