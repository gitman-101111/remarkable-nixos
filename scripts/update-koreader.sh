#!/usr/bin/env bash
# Bump the pinned KoReader release in modules/koreader.nix to the latest stable
# GitHub release (or an explicit version), fetching the matching hash.
#
# KoReader is pinned by version + hash (a fixed-output fetchurl of the official
# reMarkable aarch64 release zip) so builds stay reproducible and the A/B slots
# stay rollback-safe. This script automates the tedious part — finding the new
# tag and its hash — then rewrites the two `default =` lines in place and shows
# the diff. It does NOT rebuild or deploy: review the diff, commit, then run
# your normal rebuild + deploy.sh / sdp-flash.sh.
#
# Usage:
#   ./scripts/update-koreader.sh            # → latest stable release
#   ./scripts/update-koreader.sh 2026.04    # → a specific version
#   ./scripts/update-koreader.sh --force …  # rewrite even if unchanged
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NIX="$HERE/../modules/koreader.nix"
[ -f "$NIX" ] || { echo "!! can't find modules/koreader.nix at $NIX"; exit 1; }

FORCE=0
WANT=""
for a in "$@"; do
  case "$a" in
    --force) FORCE=1 ;;
    -*) echo "!! unknown flag: $a"; exit 1 ;;
    *) WANT="${a#v}" ;; # tolerate a leading v
  esac
done

# Current pin (for the "unchanged" short-circuit and the summary).
cur_ver=$(grep -oE 'default = "[0-9]{4}\.[0-9]{2}(\.[0-9]+)?"' "$NIX" | head -1 | grep -oE '[0-9]{4}\.[0-9]{2}(\.[0-9]+)?')
cur_hash=$(grep -oE 'default = "sha256-[^"]+"' "$NIX" | head -1 | grep -oE 'sha256-[^"]+')
[ -n "$cur_ver" ] || { echo "!! couldn't read current version from $NIX"; exit 1; }

# Target version: explicit arg, else the newest NON-prerelease from GitHub.
if [ -n "$WANT" ]; then
  ver="$WANT"
else
  echo "==> querying latest stable KoReader release…"
  ver=$(curl -fsSL https://api.github.com/repos/koreader/koreader/releases/latest \
    | grep -oE '"tag_name":[[:space:]]*"[^"]+"' | head -1 \
    | sed -E 's/.*"([^"]+)".*/\1/' | sed 's/^v//')
  [ -n "$ver" ] || { echo "!! could not determine latest release (GitHub API/rate limit?)"; exit 1; }
fi
echo "    current: $cur_ver"
echo "    target:  $ver"

if [ "$ver" = "$cur_ver" ] && [ "$FORCE" -eq 0 ]; then
  echo "==> already at $ver — nothing to do (use --force to re-pin the hash)."
  exit 0
fi

url="https://github.com/koreader/koreader/releases/download/v${ver}/koreader-remarkable-aarch64-v${ver}.zip"
echo "==> prefetching $url"
hash=$(nix store prefetch-file --json "$url" 2>/dev/null \
  | grep -oE '"hash":[[:space:]]*"[^"]+"' | sed -E 's/.*"(sha256-[^"]+)".*/\1/')
[ -n "$hash" ] || { echo "!! prefetch failed — does the release asset exist for v${ver}?"; echo "   $url"; exit 1; }
echo "    hash: $hash"

# Rewrite the two pinned defaults. The patterns are unique in the file: the only
# YYYY.MM string default is the version, and the only sha256- default is the hash.
sed -i -E \
  -e "s|default = \"[0-9]{4}\.[0-9]{2}(\.[0-9]+)?\";|default = \"${ver}\";|" \
  -e "s|default = \"sha256-[^\"]+\";|default = \"${hash}\";|" \
  "$NIX"

# Verify the file now reflects the intended pin (guards against a missed match).
grep -q "default = \"${ver}\";" "$NIX" && grep -q "default = \"${hash}\";" "$NIX" \
  || { echo "!! edit did not apply cleanly — check $NIX by hand"; exit 1; }

echo "==> updated pin in modules/koreader.nix:"
if git -C "$HERE/.." rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$HERE/.." --no-pager diff -- modules/koreader.nix || true
else
  echo "    $cur_ver -> $ver"
  echo "    $cur_hash -> $hash"
fi

cat <<EOF

==> done. KoReader pinned to v${ver}.
    Next: review the diff, commit + push remarkable-nixos, then in ~/config:
      nix flake update remarkable-nixos
      ./hosts/APT-RPM/deploy.sh        # OTA to the inactive slot (rollback-safe)
    (or sdp-flash.sh for a full both-slots reflash)
EOF
