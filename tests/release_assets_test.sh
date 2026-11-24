#!/bin/bash
# Tests for scripts/build-release-assets.sh.
#
# Usage: bash tests/release_assets_test.sh
# Requires bash and standard POSIX tools. Every build writes to a temporary folder.

set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_SCRIPT="$REPO_DIR/scripts/build-release-assets.sh"
ASSETS=(install.sh install.ps1 uninstall.sh uninstall.ps1)
TAG="v9.8.7-test"
TAG_PATTERN="$(printf '%s' "$TAG" | sed 's/[.]/\\./g')"
WORK_DIR="$(mktemp -d)"
PASSED=0
FAILED=0
trap 'rm -rf "$WORK_DIR"' EXIT

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }

check() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

# A ref in a URL path or in a quoted or assigned value, not the same word in prose.
refers_to() {
    local file="$1" ref_pattern="$2"
    grep -qE "[-/\"'=]$ref_pattern([^[:alnum:]_.-]|\$)" "$file"
}

does_not_refer_to_main() {
    ! refers_to "$1" main
}

# Turning the tag back into main must give the source byte for byte. The test tag appears
# nowhere in the sources, so every occurrence of it in an asset is a pin.
differs_only_in_ref() {
    local asset="$1" source="$2"
    ! cmp -s "$asset" "$source" && sed "s/$TAG_PATTERN/main/g" "$asset" | cmp -s - "$source"
}

verify_checksums() {
    local output_dir="$1"
    (
        cd "$output_dir" || exit 1
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum --check --strict SHA256SUMS
        else
            shasum -a 256 --check --strict SHA256SUMS
        fi
    )
}

lists_exactly_the_assets() {
    local checksums="$1"
    [ "$(awk '{ print $2 }' "$checksums" | sort)" = "$(printf '%s\n' "${ASSETS[@]}" | sort)" ]
}

build_is_refused() {
    local build_script="$1" tag="$2" output_dir="$3"
    ! bash "$build_script" "$tag" "$output_dir" && [ ! -e "$output_dir" ]
}

# Copies the build script and the four sources, so one source can be edited without
# touching the repository.
copy_sources() {
    local copy_dir="$1" name
    mkdir -p "$copy_dir/scripts"
    cp "$BUILD_SCRIPT" "$copy_dir/scripts/"
    for name in "${ASSETS[@]}"; do
        cp "$REPO_DIR/$name" "$copy_dir/$name"
    done
}

test_assets_pinned_to_tag() {
    local output_dir="$WORK_DIR/assets" name
    echo "assets are pinned to the tag and checksummed"

    check "build succeeds" bash "$BUILD_SCRIPT" "$TAG" "$output_dir"
    for name in "${ASSETS[@]}"; do
        check "$name points at the tag" refers_to "$output_dir/$name" "$TAG_PATTERN"
        check "$name does not point at main" does_not_refer_to_main "$output_dir/$name"
        check "$name differs from its source only in the ref" \
            differs_only_in_ref "$output_dir/$name" "$REPO_DIR/$name"
    done
    check "SHA256SUMS lists the four assets" lists_exactly_the_assets "$output_dir/SHA256SUMS"
    check "SHA256SUMS verifies" verify_checksums "$output_dir"
}

test_invalid_tag_refused() {
    echo "a tag with unsafe characters is refused"
    check "build refused" build_is_refused "$BUILD_SCRIPT" 'v1"&x' "$WORK_DIR/invalid-tag"
}

test_unapplied_pin_refused() {
    local leftover_dir="$WORK_DIR/leftover-source" unpinned_dir="$WORK_DIR/unpinned-source"
    echo "a ref the build cannot pin stops the build"

    copy_sources "$leftover_dir"
    sed "s/^BRANCH=\"main\"\$/BRANCH='main'/" "$REPO_DIR/install.sh" > "$leftover_dir/install.sh"
    check "a reference to main left after pinning is refused" \
        build_is_refused "$leftover_dir/scripts/build-release-assets.sh" "$TAG" "$WORK_DIR/leftover-assets"

    copy_sources "$unpinned_dir"
    sed "s|unlazier/main|unlazier/latest|g" "$REPO_DIR/uninstall.sh" > "$unpinned_dir/uninstall.sh"
    check "a file without a ref to pin is refused" \
        build_is_refused "$unpinned_dir/scripts/build-release-assets.sh" "$TAG" "$WORK_DIR/unpinned-assets"
}

main() {
    test_assets_pinned_to_tag
    test_invalid_tag_refused
    test_unapplied_pin_refused
    echo
    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

main
