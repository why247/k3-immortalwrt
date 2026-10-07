#!/bin/sh
# Apply the HomeProxy redirect/tproxy patch set to a clean luci-app-homeproxy tree.
#
# Usage: apply-patches.sh <path-to-luci-app-homeproxy>
#
# The script NEVER skips silently: every patch is first verified with
# `patch --dry-run`, and the whole run aborts (non-zero exit) on the first
# mismatch. A mismatch means the upstream source moved on and the patch set
# needs a refresh -- fix the patches, do not work around them.
#
# Idempotent: if a patch is already applied (reverse dry-run succeeds),
# it is skipped and counted as success.
set -eu

# --fuzz=0: any context mismatch is a hard failure, never a silent best-effort.
PATCH_OPTS="-p1 --fuzz=0 --forward --batch"

SRC_DIR="${1:?usage: apply-patches.sh <path-to-luci-app-homeproxy-source>}"
PATCH_DIR="$(cd "$(dirname "$0")" && pwd)/patches"

[ -d "$SRC_DIR" ] || { echo "error: source dir not found: $SRC_DIR" >&2; exit 1; }
[ -d "$PATCH_DIR" ] || { echo "error: patches dir not found: $PATCH_DIR" >&2; exit 1; }

# Idempotent: the patch set is stacked, so per-patch reverse checks cannot
# detect a fully applied tree; a stamp file written after success does.
STAMP="$SRC_DIR/.homeproxy-rt-applied"
if [ -f "$STAMP" ]; then
	echo "HomeProxy patch set already applied (stamp found), skipping."
	exit 0
fi

# Patches are stacked (a later patch may depend on an earlier one), so the
# verification pass applies them in order to a scratch copy of the tree.
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
cp -a "$SRC_DIR/." "$SCRATCH/"

count=0
skipped=0
for p in "$PATCH_DIR"/*.patch; do
	[ -f "$p" ] || continue
	count=$((count + 1))
	name="$(basename "$p")"
	printf 'checking %s...\n' "$name"
	# If reverse dry-run succeeds, patch is already applied -> skip (idempotent)
	if patch $PATCH_OPTS --dry-run -R --silent -d "$SCRATCH" < "$p" 2>/dev/null; then
		printf '  already applied, skipping %s\n' "$name"
		skipped=$((skipped + 1))
		continue
	fi
	if ! patch $PATCH_OPTS --silent -d "$SCRATCH" < "$p"; then
		printf 'error: PATCH MISMATCH: %s does not apply cleanly to %s\n' "$name" "$SRC_DIR" >&2
		printf 'error: upstream source has changed; refresh the patch set instead of skipping it.\n' >&2
		exit 1
	fi
done

[ "$count" -gt 0 ] || { echo "error: no patch files found in $PATCH_DIR" >&2; exit 1; }

applied=0
for p in "$PATCH_DIR"/*.patch; do
	[ -f "$p" ] || continue
	name="$(basename "$p")"
	# Skip if already applied
	if patch $PATCH_OPTS --dry-run -R --silent -d "$SRC_DIR" < "$p" 2>/dev/null; then
		continue
	fi
	printf 'applying %s...\n' "$name"
	if ! patch $PATCH_OPTS --silent -d "$SRC_DIR" < "$p"; then
		printf 'error: failed to apply %s\n' "$name" >&2
		exit 1
	fi
	applied=$((applied + 1))
done

touch "$STAMP"
printf 'All %d patches applied successfully (%d newly applied, %d already applied).\n' "$count" "$applied" "$skipped"

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
