# Qobuz Connect for moOde — preview build

Adds Qobuz Connect to moOde as a renderer, like AirPlay or Spotify Connect: pick your
moOde player as the output device in the Qobuz app and it plays there, in hi-res, with
metadata and cover art on the moOde screen.

**No login on the player.** The Qobuz app hands the player its own session when you cast
to it, so nothing on the Pi stores your password and two people with separate accounts
can use the same player. The most recent cast takes over.

This is unmerged, unofficial work. Read the caveats before installing.

## Install

```bash
curl -fsSLO https://github.com/PhilipVinc/moode/releases/download/<tag>/moode-qobuz-connect.tar.gz
tar xzf moode-qobuz-connect.tar.gz && sudo ./moode-qobuz-connect/install.sh
```

Then:

1. `sudo reboot` — required. `worker.php` caches its PHP includes, so the Qobuz jobs
   only exist once it restarts.
2. In moOde: **Configure → Renderers → Qobuz Connect** → turn it **on**.
3. Open the Qobuz app on your phone or desktop, start a track, and pick your player
   from the output/device list.

Nothing to log in to. Leave *Local pairing* on (the default).

## Uninstall

```bash
sudo /home/moode/qobuz-connect-uninstall
sudo reboot
```

That is a symlink the installer creates, pointing at the restore script of the backup
that holds your pre-Qobuz state. Use it rather than
`/home/moode/qobuz-gui-backup-*/restore.sh`: once there is more than one backup that
glob expands to several paths, and `sudo` silently runs the oldest one with the rest as
ignored arguments.

Every file the installer replaced was backed up in that directory, and the restore is
targeted: it
puts those files back, removes the ones that were added, drops the `cfg_qobuz` table,
removes the two `cfg_system` rows, restores `feat_bitmask` to its exact pre-install
value, removes the `qbzd` binary and its runtime state, and re-enables `qbzd.service` if
you had one. A full copy of the pre-install database is kept at
`moode-sqlite3.db.bak` in the same directory as a manual last resort — it is
deliberately *not* used by default, because restoring it would revert every setting you
changed since installing.

`restore.sh` refuses to run if moOde has been updated since the install — see below.

## Caveats

- **moOde 10.3.2 (`10.3.2-1moode1`), aarch64 only.** The installer checks and refuses
  otherwise (`--force` overrides, at your own risk). It replaces both minified JS
  bundles wholesale and patches PHP against *this release's built files*; on another
  release it either fails or silently reverts that release's own fixes.
- **A Qobuz subscription is required.** Hi-res needs a hi-res plan.
- **By default Qobuz playback takes the DAC directly, and only when nothing would be
  lost.** *Output routing* defaults to *ALSA output mode (Auto)*, which hands the DAC the
  track's own rate — no resampling — whenever Audio Config has Output mode set to Direct
  and no DSP is enabled. With any DSP on, or Output mode set to Plug, it stays on moOde's
  output chain exactly as before. Going direct reserves the DAC while a Qobuz session is
  active, so nothing else can play through it meanwhile. Set *Output routing* to
  *Software* to keep the old behaviour unconditionally.
- **Tracks are not cached by default.** *Track cache* defaults to stream-only, which
  writes nothing to the SD card — a hi-res track is 60–80 MB. Gapless playback needs the
  cache, so it is unavailable until you turn caching on; the control says so.
- **It replaces ~26 files under `/var/www`, including `js/lib.min.js` and
  `js/main.min.js`.** If you have your own modifications to any of them, they are backed
  up but replaced.
- **A moOde update wipes the GUI half of this.** The update replaces `/var/www`
  wholesale, so the Qobuz page and the bundles vanish, while `/usr/local/bin/qbzd`, the
  ALSA config and the `cfg_qobuz` table survive — an orphaned daemon with no UI, and
  `feat_bitmask` likely rewritten. **Do not run the old `restore.sh` after an update**
  (it will refuse, and print manual cleanup steps). Recovery is a new package grafted
  against the new release, not a re-run of this one.
- **The `qbzd` binary is an unsigned prebuilt from a fork release**
  ([PhilipVinc/qbz](https://github.com/PhilipVinc/qbz)), downloaded at install time by
  `/var/www/util/qobuz-installer.sh`.
- **Expect rough edges.** Resuming at an offset (switching output mid-track) takes
  several seconds to become audible — the download walks to the offset — and is reported
  as buffering while it does.
- **Keep the screensaver layout on `Default`.** The JS bundles come from `develop`, which
  has reworked the renderer metadata display into a "wide layout" (a `rmwide` body class
  and new markup). The styling for it lives in `styles.min.css` and in a wrapper `div` in
  `header.php` — neither of which this package ships, because replacing a release's whole
  stylesheet and its built header is a far bigger intrusion than replacing two JS
  bundles. So with **Appearance → Screen saver → Layout** set to anything other than
  `Default`, the renderer display (Qobuz, AirPlay and Spotify alike) renders unstyled.
  `Default` is the shipped value and is unaffected.
- If you already run a standalone `qbz`/`qbzd` install, the installer disables its
  `qbzd.service`: two daemons compete for the audio device, and the unit's
  `ExecStartPre` clears the flag moOde uses to draw the Renderer Active overlay. The
  uninstall puts it back.

## Attribution

Qobuz Connect support is built on **qbzd**, from the
[qbz](https://github.com/vicrodh/qbz) project by vicrodh, via the
[PhilipVinc/qbz](https://github.com/PhilipVinc/qbz) fork (which adds the local pairing
this package depends on). moOde is by Tim Curtis and the moOde audio player project.

Not affiliated with or endorsed by Qobuz.

## For maintainers

The package is built by `contrib/qobuz-connect/pack.sh`, which reads
`contrib/qobuz-connect/manifest.txt` — that file records every shipped path, where it
comes from, and what is deliberately left out.

The branch is based on the **10.3.2 release** (`upstream/master`), not on `develop`. That
is deliberate and load-bearing: the package installs onto 10.3.2, so building it from the
same code means every payload file can come straight from the branch and the JS bundles
match the release they land on. The product changes also live on
`feature/qobuz-connect-pairing`, which IS based on `develop` — that is the PR branch, and
the two are maintained separately on purpose.
