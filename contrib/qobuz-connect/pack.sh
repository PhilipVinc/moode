#!/bin/bash
# Build the Qobuz Connect preview tarball. Runs on the DEV MACHINE, from
# anywhere inside the moode repo.
#
#   ./contrib/qobuz-connect/pack.sh [tag]
#
# Output: dist/moode-qobuz-connect-<tag>.tar.gz, containing install.sh at the
# archive root next to the payload tree, so a tester runs:
#
#   tar xzf moode-qobuz-connect-<tag>.tar.gz
#   sudo ./moode-qobuz-connect/install.sh
#
# What ships and where each file comes from is manifest.txt, not this script.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
MANIFEST="$HERE/manifest.txt"
VENDOR="$HERE/payload-10.3.2"
TAG="${1:-$(git -C "$REPO" rev-parse --short HEAD)}"
NAME="moode-qobuz-connect"
OUT="$REPO/dist"
STAGE="$OUT/$NAME"

command -v md5sum >/dev/null 2>&1 && MD5="md5sum" || MD5="md5 -r"

echo "== repo: $REPO"
echo "== tag:  $TAG"

# ---------------------------------------------------------------- gulp bundles
# ALWAYS clean first: gulp caches, and a stale bundle is invisible until a
# tester hits a bug that was fixed weeks ago.
echo "== building JS bundles (gulp clean --all && gulp build)"
cd "$REPO"
[ -d node_modules ] || npm install
npx gulp clean --all
npx gulp build
for b in lib.min.js main.min.js; do
	[ -s "$REPO/build/develop/js/$b" ] || { echo "!! gulp produced no build/develop/js/$b"; exit 1; }
done

# ------------------------------------------------------------------- assemble
rm -rf "$STAGE"
mkdir -p "$STAGE"
install -m 755 "$HERE/install.sh" "$STAGE/install.sh"

stale=0
count=0
: > "$OUT/.manifest.body"

while IFS=$'\t' read -r prov path; do
	# skip comments and blanks
	case "${prov:-}" in ''|'#'*) continue;; esac
	path="$(echo "$path" | tr -d '[:space:]')"
	[ -n "$path" ] || continue
	dest="$STAGE/$path"
	mkdir -p "$(dirname "$dest")"

	case "$prov" in
		branch)
			cp -a "$REPO/$path" "$dest"
			;;
		branch+min)
			# The release-build include transform. moOde images ship minified
			# includes; a page copied raw from the source tree renders with no
			# footer and no JS on a real Pi.
			sed -e "s|include('footer.php')|include(\"footer.min.php\")|" \
			    -e 's|include("footer.php")|include("footer.min.php")|' \
			    "$REPO/$path" > "$dest"
			grep -q 'footer.min.php' "$dest" || { echo "!! $path: footer transform did not apply"; exit 1; }
			;;
		built)
			cp -a "$REPO/build/develop/js/$(basename "$path")" "$dest"
			;;
		vendored)
			cp -a "$VENDOR/$path" "$dest"
			# Warn when the branch has moved under a file we froze — that is the
			# signal to redo the graft (see payload-10.3.2/CAPTURED.md).
			was=$(awk -v p="$path" '$2 == p {print $1}' "$VENDOR/CAPTURED.md" | tail -1)
			now=$($MD5 "$REPO/$path" | awk '{print $1}')
			if [ -n "$was" ] && [ "$was" != "$now" ]; then
				echo "!! STALE VENDOR: $path changed on the branch since it was captured"
				echo "!!   captured against $was, branch is now $now"
				stale=1
			fi
			;;
		*)
			echo "!! unknown provenance '$prov' for $path"; exit 1
			;;
	esac

	[ -e "$dest" ] || { echo "!! missing after copy: $path"; exit 1; }
	printf '%s\t%s\t%s\n' "$prov" "$($MD5 "$dest" | awk '{print $1}')" "$path" >> "$OUT/.manifest.body"
	count=$((count + 1))
done < "$MANIFEST"

# Leftovers from live editing on the Pi must never ship.
find "$STAGE" -name '*.orig' -print -delete

# Shipped manifest: the committed provenance table, plus an md5 per file.
{
	echo "# Qobuz Connect preview payload — $TAG"
	echo "# built $(date -u +%Y-%m-%dT%H:%M:%SZ) from $(git -C "$REPO" rev-parse HEAD)"
	echo "# columns: provenance, md5, path"
	echo "#"
	echo "# See contrib/qobuz-connect/manifest.txt in the repo for what each"
	echo "# provenance means and what is deliberately NOT shipped."
	echo
	sort -k3 "$OUT/.manifest.body"
} > "$STAGE/manifest.txt"
rm -f "$OUT/.manifest.body"

install -m 644 "$HERE/README.md" "$STAGE/README.md"

# ---------------------------------------------------------------------- pack
#
# macOS hygiene, and NOT optional. Files copied on a Mac carry xattrs
# (com.apple.provenance at minimum), and bsdtar stores each one as a separate
# AppleDouble `._name` member. Those extract onto the Pi as real files — and
# ALSA parses EVERY file in /etc/alsa/conf.d, so a binary `._qbzd-devices.conf`
# makes it discard its entire configuration: no output devices at all, on a
# music player. (Found exactly that way on a real install.) Strip the xattrs,
# tell bsdtar not to synthesise the members, then verify none slipped through.
[ "$(uname -s)" = "Darwin" ] && xattr -cr "$STAGE" 2>/dev/null || true
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -print -delete

# Per-tag directory, STABLE filename: the release asset must be called
# moode-qobuz-connect.tar.gz so the documented curl command keeps working across
# releases (the tag lives in the URL path, not the filename).
mkdir -p "$OUT/$TAG"
TARBALL="$OUT/$TAG/$NAME.tar.gz"
rm -f "$TARBALL"
COPYFILE_DISABLE=1 tar --no-xattrs --no-mac-metadata -czf "$TARBALL" -C "$OUT" "$NAME" 2>/dev/null \
	|| COPYFILE_DISABLE=1 tar -czf "$TARBALL" -C "$OUT" "$NAME"

if tar tzf "$TARBALL" | grep -E '(^|/)(\._|\.DS_Store)' ; then
	echo "!! the archive contains macOS metadata members (listed above)."
	echo "!! Those extract as real files and break ALSA. Refusing to ship it."
	rm -f "$TARBALL"
	exit 1
fi

echo
echo "== payload ($count files):"
(cd "$STAGE" && find . -type f | sed 's|^\./|   |' | sort)
echo
echo "== $TARBALL"
echo "== $(du -h "$TARBALL" | awk '{print $1}') archive, $(du -sh "$STAGE" | awk '{print $1}') unpacked"
if [ "$stale" -eq 1 ]; then
	echo
	echo "!! One or more vendored files are stale — see the STALE VENDOR lines above."
	echo "!! The tarball was still written, but re-graft before shipping it."
	exit 2
fi
