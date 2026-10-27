#!/usr/bin/env bash
#############################################################################
#    OLS PRO - shimguard tests on a FAKE tree (never touches the live box). #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
# Builds the artcp incident layout under a temp dir, then:
#   unrecorded host -> fix/watch refuse (2)
#   clean check (0) -> tamper -> check (1) -> fix -> check (0) -> undo -> check (1)
#   bin/litespeed swap, lsws_env export, symlinked unit undo, preload allowlisting,
#   upgrade (not rolled back) vs LSWS swap (restored), watch restart, old systemd.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SG="$HERE/../olspro-shimguard.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/shimguard-test.XXXXXX")"
export SHIMGUARD_ROOT="$T/root" SHIMGUARD_PROC="$T/proc"
L="$SHIMGUARD_ROOT/usr/local/lsws"
ST="$SHIMGUARD_ROOT/var/lib/olspro-shimguard"
PASS=0
FAILN=0

cleanup() { chattr -R -i "$T" 2>/dev/null; rm -rf "$T"; }
trap cleanup EXIT

expect()
{
    local want="$1" name="$2" got
    shift 2
    "$@" > "$T/out" 2>&1
    got=$?
    if [ "$got" = "$want" ]; then
        PASS=$((PASS + 1)); echo "PASS $name (exit $got)"
    else
        FAILN=$((FAILN + 1)); echo "FAIL $name: exit $got, want $want"; sed 's/^/    /' "$T/out"
    fi
}

grep_out()
{
    if grep -q -- "$1" "$T/out"; then
        PASS=$((PASS + 1)); echo "PASS output has: $1"
    else
        FAILN=$((FAILN + 1)); echo "FAIL output lacks: $1"; sed 's/^/    /' "$T/out"
    fi
}

assert()
{
    local name="$1"
    shift
    if "$@"; then
        PASS=$((PASS + 1)); echo "PASS $name"
    else
        FAILN=$((FAILN + 1)); echo "FAIL $name"
    fi
}

nbackups() { ls -1 "$ST/backup" 2>/dev/null | wc -l | tr -d ' '; }
clean_proc()
{
    printf 'PATH=/usr/bin\0' > "$SHIMGUARD_PROC/4242/environ"
    printf '7f0000-7f1000 r-xp 00000000 08:01 1 /usr/lib64/libc.so.6\n' > "$SHIMGUARD_PROC/4242/maps"
}
dirty_proc()
{
    printf 'PATH=/usr/bin\0LD_PRELOAD=/usr/local/ecp/lsws/socket.so\0' > "$SHIMGUARD_PROC/4242/environ"
    printf '7f2000-7f3000 r-xp 00000000 08:01 2 /usr/local/ecp/lsws/socket.so\n' >> "$SHIMGUARD_PROC/4242/maps"
}

# --- clean layout ---------------------------------------------------------
mkdir -p "$L/bin" "$SHIMGUARD_ROOT/etc/cron.d" "$SHIMGUARD_ROOT/etc/cron.daily" \
         "$SHIMGUARD_ROOT/var/spool/cron" "$SHIMGUARD_ROOT/etc/systemd/system" "$SHIMGUARD_PROC/4242"
printf '\177ELF-olspro-build LiteSpeed/1.9.4 Open (lsquic) BUILD' > "$L/bin/openlitespeed"
chmod 755 "$L/bin/openlitespeed"
ln -s openlitespeed "$L/bin/lshttpd"
ln -s lshttpd "$L/bin/litespeed"
printf '#!/bin/sh\n. "$(dirname "$0")"/lsws_env\nexec "$(dirname "$0")/litespeed" "$@"\n' > "$L/bin/lswsctrl"
printf 'PIDFILE=/tmp/lshttpd/lshttpd.pid\n' > "$L/bin/lsws_env"
printf '[Service]\nType=forking\nExecStart=/usr/local/lsws/bin/lswsctrl start\nEnvironmentFile=-/etc/sysconfig/lsws\n' \
    > "$SHIMGUARD_ROOT/etc/systemd/system/lshttpd.service"
# rc-inst.sh: lsws.service is a symlink to lshttpd.service
ln -s lshttpd.service "$SHIMGUARD_ROOT/etc/systemd/system/lsws.service"
mkdir -p "$SHIMGUARD_ROOT/etc/sysconfig"
printf 'OPTS=\n' > "$SHIMGUARD_ROOT/etc/sysconfig/lsws"
printf 'SHELL=/bin/bash\n0 3 * * * root /usr/local/bin/backup.sh\n' > "$SHIMGUARD_ROOT/etc/crontab"
printf 'lshttpd\n' > "$SHIMGUARD_PROC/4242/comm"
clean_proc

# --- not (yet) a recorded OLS PRO install: never change anything -----------
printf '*/30 * * * * /usr/local/lsws/bin/lshttpd -r\n' > "$SHIMGUARD_ROOT/var/spool/cron/root"
expect 1 "check unrecorded host with LSWS licence cron" "$SG" check
expect 2 "fix refuses on unrecorded host" "$SG" fix
grep_out "not a recorded OLS PRO install"
expect 2 "watch alerts only on unrecorded host" "$SG" watch
assert "unrecorded: licence cron untouched" grep -q '^\*/30' "$SHIMGUARD_ROOT/var/spool/cron/root"
assert "unrecorded: no backup dir" [ "$(nbackups)" = 0 ]
rm -f "$SHIMGUARD_ROOT/var/spool/cron/root"

expect 0 "record manifest"      "$SG" record
expect 0 "fix on clean tree (drop-ins only)" "$SG" fix
expect 0 "check clean tree"     "$SG" check
grep_out "matches manifest"
grep_out "litespeed -> openlitespeed"
expect 0 "fix on clean tree again" "$SG" fix
grep_out "nothing to fix"

# --- artcp incident -------------------------------------------------------
chattr -i "$L/bin/openlitespeed" 2>/dev/null
mkdir -p "$SHIMGUARD_ROOT/usr/local/ecp/lsws"
printf '\177ELF-shim' > "$SHIMGUARD_ROOT/usr/local/ecp/lsws/socket.so"
printf '/usr/local/ecp/lsws/socket.so /usr/lib64/libsnoopy.so\n' > "$SHIMGUARD_ROOT/etc/ld.so.preload"
rm -f "$L/bin/lshttpd"
printf '\177ELF-vendor-lshttpd LiteSpeed/6.3 Enterprise' > "$L/bin/lshttpd"
chmod 755 "$L/bin/lshttpd"
printf '\177ELF-vendor-replaced LiteSpeed/6.3 Enterprise' > "$L/bin/openlitespeed"
printf '*/5 * * * * root /usr/local/ecp/bin/esp litespeed cron >/dev/null 2>&1\n' > "$SHIMGUARD_ROOT/etc/cron.d/esp"
printf '*/30 * * * * /usr/local/lsws/bin/lshttpd -r\n' > "$SHIMGUARD_ROOT/var/spool/cron/root"
printf '#!/bin/sh\n/usr/local/ecp/bin/esp litespeed license refresh\n' > "$SHIMGUARD_ROOT/etc/cron.daily/esp-lic"
chmod 755 "$SHIMGUARD_ROOT/etc/cron.daily/esp-lic"
printf 'LD_PRELOAD=/usr/local/ecp/lsws/socket.so\n' >> "$SHIMGUARD_ROOT/etc/sysconfig/lsws"
printf 'export LD_PRELOAD=/usr/local/ecp/lsws/socket.so\n' >> "$L/bin/lsws_env"
printf 'Environment=LD_PRELOAD=/usr/local/ecp/lsws/socket.so\n' >> "$SHIMGUARD_ROOT/etc/systemd/system/lshttpd.service"
dirty_proc

expect 1 "check tampered tree" "$SG" check
for s in "etc/cron.d/esp" "var/spool/cron/root" "cron.daily/esp-lic" "KNOWN SHIM" \
         "sysconfig/lsws sets LD_PRELOAD" "lsws_env sets LD_PRELOAD" "lshttpd.service sets LD_PRELOAD" \
         "libsnoopy.so into every process (not a known shim" "pid 4242" "shim mapped" \
         "replaced binary" "replaced lshttpd" "shim payload present"; do
    grep_out "$s"
done
assert "symlinked unit reported once (resolved)" [ "$(grep -c 'service sets LD_PRELOAD' "$T/out")" = 1 ]

expect 1 "fix tampered tree (running pid still dirty)" "$SG" fix
grep_out "restored .*openlitespeed from golden copy"
grep_out "relinked"
grep_out "running workers still carry the shim"
BK="$(sed -n 's/.*undo with: [^ ]* undo \(.*\))$/\1/p' "$T/out" | head -1)"
TAB="$(printf '\t')"
assert "actions.log backs up the resolved unit file" grep -q "^backup${TAB}.*/etc/systemd/system/lshttpd.service${TAB}" "$BK/actions.log"
assert "actions.log has no symlink unit backup" sh -c "! grep -q 'lsws.service${TAB}' '$BK/actions.log'"

# simulate the lsws restart that drops the shim from workers
clean_proc
expect 0 "check after fix + restart" "$SG" check

assert "ld.so.preload keeps the non-shim entry" grep -qx '/usr/lib64/libsnoopy.so' "$SHIMGUARD_ROOT/etc/ld.so.preload"
assert "ld.so.preload shim stripped" sh -c "! grep -q socket.so '$SHIMGUARD_ROOT/etc/ld.so.preload'"
assert "cron commented" grep -q '^#olspro-shimguard-disabled# \*/5' "$SHIMGUARD_ROOT/etc/cron.d/esp"
assert "cron.daily script disabled" [ ! -x "$SHIMGUARD_ROOT/etc/cron.daily/esp-lic" ]
assert "lsws_env export commented" grep -q '^#olspro-shimguard-disabled# export LD_PRELOAD' "$L/bin/lsws_env"
assert "lsws.service still a symlink" [ -L "$SHIMGUARD_ROOT/etc/systemd/system/lsws.service" ]

expect 0 "undo $BK" "$SG" undo "$BK"
expect 1 "check after undo (incident restored = reversible)" "$SG" check
grep_out "KNOWN SHIM"
grep_out "replaced lshttpd"
grep_out "shim payload present"
assert "undo restored vendor lshttpd bytes" [ "$(cat "$L/bin/lshttpd")" = "$(printf '\177ELF-vendor-lshttpd LiteSpeed/6.3 Enterprise')" ]
assert "undo restored symlinked unit content (no marker)" sh -c "! grep -q olspro-shimguard-disabled '$SHIMGUARD_ROOT/etc/systemd/system/lshttpd.service'"

# fix again, then --all-preload strips the non-shim entry too
expect 0 "fix again" "$SG" fix
expect 0 "fix --all-preload" "$SG" fix --all-preload
assert "--all-preload removed ld.so.preload" [ ! -e "$SHIMGUARD_ROOT/etc/ld.so.preload" ]

# --- bin/litespeed swapped (what lswsctrl actually execs) -----------------
rm -f "$L/bin/litespeed"
printf '\177ELF-vendor-litespeed LiteSpeed/6.3 Enterprise' > "$L/bin/litespeed"
chmod 755 "$L/bin/litespeed"
expect 1 "check litespeed swap" "$SG" check
grep_out "replaced litespeed"
expect 0 "fix litespeed swap" "$SG" fix
assert "litespeed relinked to lshttpd" [ "$(readlink "$L/bin/litespeed")" = lshttpd ]

# --- upgrade: new OLS build is reported, never rolled back ----------------
printf '\177ELF-olspro-build LiteSpeed/1.9.5 Open (lsquic) BUILD2' > "$L/bin/openlitespeed"
NB1="$(nbackups)"
expect 0 "check after OLS upgrade (warn only)" "$SG" check
grep_out "upgrade?"
expect 0 "watch after OLS upgrade" "$SG" watch
assert "upgraded binary kept" grep -q 'BUILD2' "$L/bin/openlitespeed"
assert "watch on upgrade made no backup" [ "$(nbackups)" = "$NB1" ]
expect 0 "record upgraded binary" "$SG" record
expect 0 "check after record" "$SG" check
grep_out "matches manifest"

# --- LSWS swap via watch: restored ----------------------------------------
printf '\177ELF-lsws LiteSpeed/6.3 Enterprise' > "$L/bin/openlitespeed"
expect 1 "watch restores swapped binary" "$SG" watch
assert "golden BUILD2 restored" grep -q 'BUILD2' "$L/bin/openlitespeed"

# --- watch: proc-only findings -> restart, no backup dir ------------------
dirty_proc
cat > "$T/restart.sh" <<EOF
#!/bin/sh
printf 'PATH=/usr/bin\0' > "$SHIMGUARD_PROC/4242/environ"
printf '7f0000-7f1000 r-xp 00000000 08:01 1 /usr/lib64/libc.so.6\n' > "$SHIMGUARD_PROC/4242/maps"
EOF
chmod 755 "$T/restart.sh"
NB2="$(nbackups)"
export SHIMGUARD_RESTART_CMD="$T/restart.sh"
expect 1 "watch restarts when only procs are dirty" "$SG" watch
grep_out "restarted lsws"
grep_out "no on-disk change was needed"
assert "proc-only watch made no backup dir" [ "$(nbackups)" = "$NB2" ]
expect 0 "check after watch restart" "$SG" check
dirty_proc
expect 1 "watch does not restart twice within interval" "$SG" watch
grep_out "not restarting again"
unset SHIMGUARD_RESTART_CMD
clean_proc

# --- backup retention -----------------------------------------------------
for i in 1 2 3 4 5; do
    printf '*/5 * * * * root /usr/local/ecp/bin/esp litespeed cron\n' > "$SHIMGUARD_ROOT/etc/cron.d/esp$i"
    SHIMGUARD_KEEP_BACKUPS=3 "$SG" fix > /dev/null 2>&1
    sleep 1
done
assert "backup retention keeps 3" [ "$(nbackups)" = 3 ]

# --- systemd < 235: Environment= fallback drop-in, warned ------------------
export SHIMGUARD_SYSTEMD_VERSION=219
expect 0 "check on systemd 219 (outdated drop-in is a warning)" "$SG" check
grep_out "modified/outdated"
expect 0 "fix on systemd 219" "$SG" fix
expect 0 "check on systemd 219 after fix" "$SG" check
grep_out "ignores UnsetEnvironment"
assert "old-systemd drop-in blanks LD_PRELOAD" grep -q '^Environment=LD_PRELOAD= LD_AUDIT=' \
    "$SHIMGUARD_ROOT/etc/systemd/system/lshttpd.service.d/50-olspro-nopreload.conf"
assert "own drop-in not flagged as LD_PRELOAD source" sh -c "! grep -q 'nopreload.conf sets LD_PRELOAD' '$T/out'"
unset SHIMGUARD_SYSTEMD_VERSION

echo "== $PASS passed, $FAILN failed"
[ "$FAILN" -eq 0 ]
