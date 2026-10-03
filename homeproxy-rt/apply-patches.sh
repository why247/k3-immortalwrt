#!/bin/sh
# Apply the HomeProxy redirect/tproxy patch set to a clean luci-app-homeproxy tree.
#
# Usage: apply-patches.sh <path-to-luci-app-homeproxy>
#
# The script NEVER skips silently: every patch is first verified with
# `patch --dry-run`, and the whole run aborts (non-zero exit) on the first
# mismatch. A mismatch means the upstream source moved on and the patch set
# needs a refresh -- fix the patches, do not work around them.
set -eu

# --fuzz=0: any context mismatch is a hard failure, never a silent best-effort.
PATCH_OPTS="-p1 --fuzz=0"

SRC_DIR="${1:?usage: apply-patches.sh <path-to-luci-app-homeproxy-source>}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patches"

[ -d "$SRC_DIR" ] || { echo "error: source dir not found: $SRC_DIR" >&2; exit 1; }
[ -d "$PATCH_DIR" ] || { echo "error: patches dir not found: $PATCH_DIR" >&2; exit 1; }

count=0
for p in "$PATCH_DIR"/*.patch; do
	[ -f "$p" ] || continue
	count=$((count + 1))
	name="$(basename "$p")"
	printf 'checking %s...\n' "$name"
	if ! patch $PATCH_OPTS --dry-run --silent -d "$SRC_DIR" < "$p"; then
		printf 'error: PATCH MISMATCH: %s does not apply cleanly to %s\n' "$name" "$SRC_DIR" >&2
		printf 'error: upstream source has changed; refresh the patch set instead of skipping it.\n' >&2
		exit 1
	fi
done

[ "$count" -gt 0 ] || { echo "error: no patch files found in $PATCH_DIR" >&2; exit 1; }

for p in "$PATCH_DIR"/*.patch; do
	[ -f "$p" ] || continue
	name="$(basename "$p")"
	printf 'applying %s...\n' "$name"
	if ! patch $PATCH_OPTS --silent -d "$SRC_DIR" < "$p"; then
		printf 'error: failed to apply %s\n' "$name" >&2
		exit 1
	fi
done

printf 'All %d patches applied successfully.\n' "$count"

# Ship pre-seeded data files (e.g. the initial CN IP list so the first boot
# already has kernel-layer bypass data before the first resource update).
FILES_DIR="$PATCH_DIR/files"
if [ -d "$FILES_DIR" ]; then
	(cd "$FILES_DIR" && find . -type f | while IFS= read -r f; do
		dest="$SRC_DIR/${f#./}"
		mkdir -p "$(dirname "$dest")"
		cp -f "$FILES_DIR/$f" "$dest"
		printf 'installed data file: %s\n' "${f#./}"
	done)
fi
