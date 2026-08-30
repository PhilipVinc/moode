#!/bin/bash
# Qobuz Connect preview installer for moOde 10.3.3 (run with sudo on the Pi).
#
# Layout mirrors the moOde tree: www/ -> /var/www, everything else -> /. Every
# file this replaces is backed up under $BK together with a generated restore.sh
# that puts the Pi back.
#
# Built by contrib/qobuz-connect/pack.sh — see README.md for what this installs
# and what it cannot undo.
set -euo pipefail

STAGING="$(cd "$(dirname "$0")" && pwd)"

# Refuse before touching anything if the payload is not sitting next to us —
# otherwise running the script from the wrong place (a copy in /tmp, say) gets as
# far as creating an empty backup directory before failing on an empty file list.
for required in www/qbz-config.php etc/alsa/conf.d/qbzd-devices.conf manifest.txt; do
	if [ ! -e "$STAGING/$required" ]; then
		echo "!! $STAGING does not look like an unpacked Qobuz Connect package"
		echo "!! (missing $required). Run install.sh from inside the extracted"
		echo "!! moode-qobuz-connect/ directory."
		exit 1
	fi
done

TS=$(date +%Y%m%d-%H%M%S)
BK="/home/moode/qobuz-gui-backup-$TS"
DB=/var/local/www/db/moode-sqlite3.db
FEAT_QOBUZ=262144
UNINSTALL_LINK=/home/moode/qobuz-connect-uninstall

# The graft replaces both JS bundles wholesale and patches PHP against 10.3.3's
# BUILT files. On any other release those patches either fail or silently revert
# that release's own fixes, so refuse by default.
WANT_VERSION="10.3.3-1moode1"
WANT_ARCH="aarch64"
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

HAVE_VERSION=$(dpkg-query -W -f='${Version}' moode-player 2>/dev/null || echo "unknown")
HAVE_ARCH=$(uname -m)
if [ "$HAVE_VERSION" != "$WANT_VERSION" ] || [ "$HAVE_ARCH" != "$WANT_ARCH" ]; then
	echo "!! This package targets moOde $WANT_VERSION on $WANT_ARCH."
	echo "!! This Pi is moOde $HAVE_VERSION on $HAVE_ARCH."
	if [ "$FORCE" -eq 0 ]; then
		echo "!! Refusing to install. Re-run with --force if you know what you are doing."
		exit 1
	fi
	echo "!! --force given; continuing anyway."
fi

echo "== staging: $STAGING"
echo "== backup:  $BK"
mkdir -p "$BK"

map_target () {
	case "$1" in
		www/*) echo "/var/www/${1#www/}";;
		*)     echo "/$1";;
	esac
}

# Never install macOS metadata or editor leftovers. pack.sh already refuses to
# build an archive containing them, but this is the layer that would actually do
# the damage: ALSA parses every file in /etc/alsa/conf.d, and one binary
# `._qbzd-devices.conf` makes it throw away its whole configuration, leaving the
# player with no output devices at all.
FILES=$(cd "$STAGING" && find www usr var etc -type f \
	! -name '._*' ! -name '.DS_Store' ! -name '*.orig' | sort)

# 1. Backups (files + DB + current qbzd binary + the built header)
for f in $FILES; do
	tgt=$(map_target "$f")
	if [ -e "$tgt" ]; then
		mkdir -p "$BK/files/$(dirname "$f")"
		cp -a "$tgt" "$BK/files/$f"
	else
		echo "$f" >> "$BK/new-files.txt"
	fi
done
cp -a "$DB" "$BK/moode-sqlite3.db.bak"
[ -x /usr/bin/qbzd ] && cp -a /usr/bin/qbzd "$BK/qbzd.usr-bin"
[ -x /usr/local/bin/qbzd ] && cp -a /usr/local/bin/qbzd "$BK/qbzd.usr-local-bin"
cp -a /var/www/header.php "$BK/header.php"

# Record the release this backup was taken against. restore.sh refuses to run
# against a different one: after a moOde update, replaying these files and this
# DB over the newer release is the one way this package can really break a Pi.
echo "$HAVE_VERSION" > "$BK/moode-version"

# Record the pre-install feat_bitmask so the rollback can be exact rather than
# "clear the bit and hope nothing else touched it".
sqlite3 "$DB" "SELECT value FROM cfg_system WHERE param='feat_bitmask'" > "$BK/feat_bitmask.pre"

# qobuz-installer.sh disables an existing enabled qbzd.service on purpose (a
# second daemon competes for the audio device, and its ExecStartPre clears
# cfg_system.qbzactive, blanking the Renderer Active overlay). Remember what it
# was so restore.sh can put it back — anyone with a standalone qbz install is
# exactly who is likely to try this package.
systemctl is-enabled qbzd.service > "$BK/qbzd.service.enabled" 2>/dev/null || true
systemctl is-active  qbzd.service > "$BK/qbzd.service.active"  2>/dev/null || true

# 2. Stop the daemon if running. SIGTERM, never -9: on SIGTERM qbzd leaves the
#    Qobuz Connect session, so the cloud drops this renderer instead of keeping a
#    zombie one registered mid-playback.
killall qbzd 2>/dev/null || true
for _ in $(seq 1 15); do pgrep -x qbzd >/dev/null || break; sleep 0.2; done

# 3. Install files
for f in $FILES; do
	install -D "$STAGING/$f" "$(map_target "$f")"
done
chown -R root:root /var/www 2>/dev/null || true
chmod +x /var/www/daemon/watchdog.sh /var/www/util/*.sh \
	/var/local/www/commandw/qbzevent.sh /usr/local/bin/moodeutl

# 4. DB: cfg_qobuz table + cfg_system rows + feature bit
sqlite3 "$DB" <<SQL
CREATE TABLE IF NOT EXISTS cfg_qobuz (id INTEGER PRIMARY KEY, param CHAR (32), value CHAR (32));
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (1, 'quality', 'hires_plus');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (2, 'gapless', 'Yes');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (3, 'normalize_volume', 'No');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (4, 'pairing', 'Yes');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (5, 'buffer_seconds', '2');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (6, 'volume_mode', 'auto');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (7, 'output_mode', 'auto');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (8, 'stream_first', 'Yes');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (9, 'track_cache', 'Yes');
INSERT OR IGNORE INTO cfg_qobuz (id, param, value) VALUES (10, 'quality_fallback', 'fallback');
INSERT OR IGNORE INTO cfg_system (id, param, value) VALUES (178, 'qobuzsvc', '0');
INSERT OR IGNORE INTO cfg_system (id, param, value) VALUES (179, 'qobuzname', 'Moode Qobuz');
UPDATE cfg_system SET value = '0' WHERE param = 'qbzactive';
UPDATE cfg_system SET value = (CAST(value AS INTEGER) | $FEAT_QOBUZ) WHERE param = 'feat_bitmask';
SQL
echo "== feat_bitmask: $(cat "$BK/feat_bitmask.pre") -> $(sqlite3 "$DB" "SELECT value FROM cfg_system WHERE param='feat_bitmask'")"

# 5. Cache-bust the two rebuilt bundles in the BUILT header (it references
#    js/lib.min.js?t=<ms>; without bumping it, browsers serve the old bundles).
T=$(date +%s%3N)
sed -i -E "s|js/lib.min.js\?t=[0-9]+|js/lib.min.js?t=$T|; s|js/main.min.js\?t=[0-9]+|js/main.min.js?t=$T|" /var/www/header.php
grep -n "min.js?t=" /var/www/header.php

# 6. qbzd itself, via the (freshly installed) fork-release installer. Retire any
#    old /usr/bin binary so /usr/local/bin/qbzd is unambiguous.
[ -x /usr/bin/qbzd ] && rm -f /usr/bin/qbzd
bash /var/www/util/qobuz-installer.sh

# 7. Restore script
cat > "$BK/restore.sh" <<EOF
#!/bin/bash
# Undo the Qobuz Connect preview install of $TS (run with sudo).
set -euo pipefail

BK="$BK"
DB="$DB"
WAS_VERSION="\$(cat "\$BK/moode-version")"
HAVE_VERSION=\$(dpkg-query -W -f='\${Version}' moode-player 2>/dev/null || echo "unknown")

# Refuse across a moOde update. These are 10.3.3 files and a 10.3.3 database;
# replaying them over a newer release would overwrite that release's own www
# tree and settings with older ones. A moOde update has already removed the
# grafted GUI on its own, so there is nothing here worth forcing.
if [ "\$HAVE_VERSION" != "\$WAS_VERSION" ]; then
	cat <<MSG
!! This backup was taken on moOde \$WAS_VERSION; this Pi now runs \$HAVE_VERSION.
!! Refusing to restore — the files and database in this backup are older than
!! the release now installed, and replaying them would damage it.
!!
!! The moOde update already replaced /var/www, so the Qobuz GUI is gone. To
!! finish cleaning up by hand:
!!   sudo rm -f /usr/local/bin/qbzd /var/local/www/qbzd-build
!!   sudo rm -f /etc/alsa/conf.d/qbzd-devices.conf
!!   sudo rm -rf /home/moode/.config/qbzd
!!   sudo sqlite3 \$DB "DROP TABLE IF EXISTS cfg_qobuz; \\
!!     DELETE FROM cfg_system WHERE id IN (178, 179);"
!! (feat_bitmask is rewritten by the update, so leave it alone.)
MSG
	exit 1
fi

# 1. Put back every replaced file
cd "\$BK/files"
for f in \$(find . -type f | sed 's|^\./||'); do
	case "\$f" in
		www/*) tgt="/var/www/\${f#www/}";;
		*)     tgt="/\$f";;
	esac
	cp -a "\$f" "\$tgt"
done

# 2. Remove the files the install ADDED
if [ -f "\$BK/new-files.txt" ]; then
	while read -r f; do
		case "\$f" in
			www/*) rm -f "/var/www/\${f#www/}";;
			*)     rm -f "/\$f";;
		esac
	done < "\$BK/new-files.txt"
fi
cp -a "\$BK/header.php" /var/www/header.php

# 3. Targeted DB rollback. NOT a wholesale copy of the pre-install database:
#    that would silently revert every setting changed since installing. The full
#    copy stays at \$BK/moode-sqlite3.db.bak as a manual last resort.
PRE_FEAT=\$(cat "\$BK/feat_bitmask.pre")
sqlite3 "\$DB" <<SQL
DROP TABLE IF EXISTS cfg_qobuz;
DELETE FROM cfg_system WHERE id IN (178, 179);
UPDATE cfg_system SET value = '\$PRE_FEAT' WHERE param = 'feat_bitmask';
SQL
echo "== feat_bitmask restored to \$PRE_FEAT"

# 4. qbzd binary, its build marker, and its runtime state. Pairing tokens are
#    memory-only by design, but the credential salt and any OAuth token from a
#    manual login persist across an uninstall.
rm -f /usr/local/bin/qbzd /usr/bin/qbzd /var/local/www/qbzd-build
rm -rf /home/moode/.config/qbzd
[ -f "\$BK/qbzd.usr-bin" ] && cp -a "\$BK/qbzd.usr-bin" /usr/bin/qbzd
[ -f "\$BK/qbzd.usr-local-bin" ] && cp -a "\$BK/qbzd.usr-local-bin" /usr/local/bin/qbzd

# 5. Put qbzd.service back the way qobuz-installer.sh found it
if [ "\$(cat "\$BK/qbzd.service.enabled" 2>/dev/null || echo none)" = "enabled" ]; then
	systemctl enable qbzd.service 2>/dev/null || true
	echo "== re-enabled qbzd.service"
fi
if [ "\$(cat "\$BK/qbzd.service.active" 2>/dev/null || echo none)" = "active" ]; then
	systemctl start qbzd.service 2>/dev/null || true
	echo "== restarted qbzd.service"
fi

# Mark this backup spent, so a later install can tell that it no longer holds a
# pre-Qobuz state, and stand down as THE uninstall if that is what we are.
touch "\$BK/restored"
if [ "\$(readlink -f "$UNINSTALL_LINK" 2>/dev/null)" = "\$BK/restore.sh" ]; then
	rm -f "$UNINSTALL_LINK"
fi

echo "Restored. Reboot to finish: sudo reboot"
EOF
chmod +x "$BK/restore.sh"

# One stable path for uninstalling, because
# `/home/moode/qobuz-gui-backup-*/restore.sh` is a trap: with more than one
# backup the glob expands to several paths and sudo silently runs the FIRST
# (oldest) one, passing the rest as ignored arguments.
#
# The link must keep pointing at the backup holding the PRE-QOBUZ state. A
# second install must NOT retarget it — this new backup's files are the previous
# install's, so restoring it would put the graft back rather than remove it. Only
# take over if there is no live link, or the one there has already been used.
if [ -e "$UNINSTALL_LINK" ] && [ ! -e "$(dirname "$(readlink -f "$UNINSTALL_LINK")")/restored" ]; then
	echo "== uninstall still points at the original backup:"
	echo "==   sudo $UNINSTALL_LINK   ->  $(readlink -f "$UNINSTALL_LINK")"
else
	ln -sfn "$BK/restore.sh" "$UNINSTALL_LINK"
	echo "== uninstall:  sudo $UNINSTALL_LINK"
fi

echo
echo "== install complete"
echo "== backup + restore.sh: $BK"
echo "== REBOOT REQUIRED — worker.php caches its PHP includes, so the Qobuz jobs"
echo "==   only exist after it restarts:  sudo reboot"
