# Vendored payload — captured from a moOde 10.3.2 Pi

These four files could not be taken from the feature branch. The branch is based on
`develop`, and each of these has diverged between 10.3.2 and `develop` for reasons that
have nothing to do with Qobuz Connect. Installing the branch version would quietly
revert a 10.3.2 Pi to `develop`'s behaviour (or, for `common.php`, to a display bug the
release already fixed).

Captured 2026-08-20 from moOde **10.3.2-1moode1**, aarch64.

| file | why it is vendored |
|---|---|
| `www/daemon/worker.php` | 10.3.2 and `develop` differ across ~46 lines of MPD library-stats/analyze work (`mpd_db_stats` vs `mpd_dbregen_count`/`mpd_dbanalyze_count`, the `analyze_library` job, where `clearLibCacheAll()` is called). The Qobuz content of both versions is identical; this copy is 10.3.2's file with the Qobuz jobs grafted in. |
| `www/inc/common.php` | 10.3.2 writes brightness to the specific i2c device `10-0045` (a release fix for Touch1/Touch2); `develop` still globs `/sys/class/backlight/*/brightness`. Shipping the branch version would break touch-display brightness. |
| `www/templates/sys-config.html` | `aria-hidden`/`aria-label` drift on modal close buttons. Cosmetic, but it is 16 lines of unrelated change to force on a tester. |
| `www/util/sysutil.sh` | `develop` has one extra `sed` expression (uncommenting `ignore_volume_control`) that 10.3.2 does not. |

## Keeping these fresh

`pack.sh` records the md5 of each vendored file's **branch counterpart** below and warns
when it changes — that is the signal that the graft has to be redone (the branch has
touched a file we froze). Recapture with:

```bash
ssh moode sudo cat /var/www/daemon/worker.php > contrib/qobuz-connect/payload-10.3.2/www/daemon/worker.php
```

...after re-applying the Qobuz changes on top of the Pi's version, not the other way
round.

### Branch-counterpart md5 at capture time

```
5a5872fa9ccd17bb078314a32d910e61  www/daemon/worker.php
dce9797c09b403ef199ec1b8f19b6f70  www/inc/common.php
3b44558be002091df000cb3b91f21985  www/templates/sys-config.html
3786fd6caac644c0f91c69c9e300e8fa  www/util/sysutil.sh
```
