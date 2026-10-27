#!/bin/bash
# Regression tests for pro/cpanel/hooks/olspro-hook (Linux: GNU stat/mv -T).
# Uses a fake LSWS tree (fake openlitespeed -t, apache2ols, lswsctrl); never
# touches /usr/local/lsws, cPanel or a running server.
#   bash pro/cpanel/tests/test-olspro-hook.sh
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="$HERE/../hooks/olspro-hook"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass + 1)); echo "ok   - $*"; }
bad() { fail=$((fail + 1)); echo "FAIL - $*"; }
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

L="$T/lsws"; mkdir -p "$L/bin" "$L/conf" "$L/logs"
# fake openlitespeed -t: prints $T/t.out, exits with $T/t.rc
cat > "$L/bin/openlitespeed" <<EOF
#!/bin/bash
cat "$T/t.out" 2>/dev/null; exit \$(cat "$T/t.rc" 2>/dev/null || echo 0)
EOF
# fake apache2ols: N vhosts from $T/a.n ; $T/a.trunc = leave one vhconf empty
cat > "$L/bin/apache2ols" <<EOF
#!/bin/bash
out=""; while [ \$# -gt 0 ]; do [ "\$1" = --out ] && { out=\$2; shift; }; shift; done
n=\$(cat "$T/a.n"); mkdir -p "\$out/vhosts"; : > "\$out/olspro_apache.conf"
for i in \$(seq 1 \$n); do
  mkdir -p "\$out/vhosts/v\$i"
  if [ -e "$T/a.trunc" ] && [ \$i -eq 1 ]; then : > "\$out/vhosts/v\$i/vhconf.conf"; else echo "docRoot /x\$i/" > "\$out/vhosts/v\$i/vhconf.conf"; fi
  printf 'virtualhost v%s {\n  configFile              %s\n}\n' \$i "\$out/vhosts/v\$i/vhconf.conf" >> "\$out/olspro_apache.conf"
done
echo "\$n vhosts, 1 listeners, 1 files, 0 warnings" >&2
EOF
printf '#!/bin/bash\nexit 0\n' > "$L/bin/lswsctrl"
chmod +x "$L"/bin/*

mkhttpd() { # $1 = vhost count, $2 = 1 to drop the last </VirtualHost>
    : > "$T/httpd.conf"
    for i in $(seq 1 "$1"); do
        printf '<VirtualHost 1.2.3.4:80>\n  ServerName v%s.test\n' "$i" >> "$T/httpd.conf"
        [ "${2:-0}" = 1 ] && [ "$i" -eq "$1" ] || echo '</VirtualHost>' >> "$T/httpd.conf"
    done
}

cat > "$T/hook.conf" <<EOF
LSWS="$L"
HTTPD_CONF="$T/httpd.conf"
STATE_DIR="$T/state"
TRUEUSERDOMAINS="$T/trueuserdomains"
PIDFILE="$T/nonexistent.pid"
STABLE_SECS=0
STABLE_MAX=1
DEBOUNCE=0
MIN_FREE_MB=0
ACTIVE_WEBSERVER=apache
EOF
export OLSPRO_HOOK_CONF="$T/hook.conf" OLSPRO_HOOK_LIB=1
# shellcheck disable=SC1090
. "$HOOK"
mkdir -p "$STATE_DIR"

# --- validate_ols: exit code is not the verdict -------------------------------
printf '2026-10-27 [WARN] [config:server] deprecated directive foo\n' > "$T/t.out"; echo 1 > "$T/t.rc"
check "validate: single WARN (rc=1) passes" validate_ols
printf '2026-10-27 [ERROR] [config:server:vhost:acct1] failed to load cert /var/cpanel/x.crt\n' > "$T/t.out"; echo 2 > "$T/t.rc"
check "validate: per-vhost ERROR (rc=2) passes" validate_ols
VALIDATE_STRICT=1
check "validate: per-vhost ERROR fails with VALIDATE_STRICT=1" eval '! validate_ols'
VALIDATE_STRICT=0
printf '2026-10-27 [ERROR] [config:server:listener:Default] failed to start listener on address *:80!\n' > "$T/t.out"
check "validate: listener ERROR fails" eval '! validate_ols'
printf '[ERROR] No listener is available, stop server!\n' > "$T/t.out"
check "validate: no-listener ERROR fails" eval '! validate_ols'
printf 'Fatal error in configuration\n' > "$T/t.out"; echo 0 > "$T/t.rc"
check "validate: Fatal error fails even with rc=0" eval '! validate_ols'
: > "$T/t.out"; echo 124 > "$T/t.rc"
check "validate: timeout/crash (rc=124) fails" eval '! validate_ols'
: > "$T/t.out"; echo 0 > "$T/t.rc"

# --- describe: valid JSON, escalation for Cpanel category, restore event -----
d=$(describe)
check "describe: valid JSON with escalateprivs on every Cpanel entry + PkgAcct::Restore" \
  python3 -c 'import json,sys
a=json.loads(sys.argv[1])
assert all(e.get("escalateprivs")==1 for e in a if e["category"]=="Cpanel"), "esc"
assert all("escalateprivs" not in e for e in a if e["category"]=="Whostmgr")
assert any(e["event"]=="PkgAcct::Restore" for e in a)' "$d"

# --- regen: generation dirs + atomic symlink ---------------------------------
# legacy layout: $OUT is a real dir with baked $OUT paths
mkdir -p "$OUT/vhosts/old"; echo "docRoot /old/" > "$OUT/vhosts/old/vhconf.conf"
printf 'virtualhost old {\n  configFile %s/vhosts/old/vhconf.conf\n}\n' "$OUT" > "$OUT/olspro_apache.conf"
mkdir -p "$OUT.prev"
mkhttpd 4; echo 4 > "$T/a.n"; printf 'a: a\nb: b\nc: c\n' > "$T/trueuserdomains"
regen; rc=$?
check "regen #1 succeeds (rc=$rc)" [ $rc -eq 0 ]
g1=$(readlink "$OUT")
check "OUT is a symlink to a g.* generation" eval '[ -L "$OUT" ] && case "$g1" in "$GEN_BASE"/g.*) true;; *) false;; esac'
check "legacy dir kept as previous generation, old .prev removed" eval 'ls -d "$GEN_BASE"/legacy.* >/dev/null 2>&1 && [ ! -e "$OUT.prev" ]'
check "synced hash recorded" [ -s "$STATE_DIR/httpd.synced" ]

# validation failure -> OUT points back at the previous generation
printf '[ERROR] [config:server:listener:SSL] failed to start listener\n' > "$T/t.out"; echo 2 > "$T/t.rc"
touch -d '2 seconds ago' "$T/httpd.conf"; mkhttpd 5; echo 5 > "$T/a.n"
regen; rc=$?
check "regen #2 fails on fatal -t error" [ $rc -ne 0 ]
check "OUT restored to generation #1" [ "$(readlink "$OUT")" = "$g1" ]
check "failed generation kept for inspection" [ -s "$GEN_BASE/failed/olspro_apache.conf" ]
check "failed hash recorded (backstop will not loop)" [ -s "$STATE_DIR/httpd.failed" ]
: > "$T/t.out"; echo 0 > "$T/t.rc"

# a WARN-only -t still syncs (regression: one WARN used to block every regen)
printf '[WARN] [config:server:vhost:v2] docRoot does not exist\n' > "$T/t.out"; echo 1 > "$T/t.rc"
regen; rc=$?
check "regen with WARN-only -t succeeds" [ $rc -eq 0 ]
g2=$(readlink "$OUT")
check "OUT moved to a new generation" [ "$g2" != "$g1" ]
: > "$T/t.out"; echo 0 > "$T/t.rc"

# truncated apache2ols output (disk full) never goes live
touch "$T/a.trunc"; mkhttpd 6; echo 6 > "$T/a.n"
regen; rc=$?
check "truncated output refused" [ $rc -ne 0 ]
check "OUT unchanged after truncated output" [ "$(readlink "$OUT")" = "$g2" ]
rm -f "$T/a.trunc"

# truncated httpd.conf refused; legitimate bulk removal accepted (no history lockout)
mkhttpd 6 1; echo 6 > "$T/a.n"
regen; rc=$?
check "unbalanced <VirtualHost> (truncated httpd.conf) refused" [ $rc -ne 0 ]
mkhttpd 2; echo 2 > "$T/a.n"; printf 'a: a\n' > "$T/trueuserdomains"
regen; rc=$?
check "bulk removal 6 -> 2 vhosts accepted" [ $rc -eq 0 ]
mkhttpd 6; echo 1 > "$T/a.n"
regen; rc=$?
check "parser collapse (1 of 6 vhosts) refused" [ $rc -ne 0 ]
FORCE=1; regen; rc=$?; FORCE=0
check "--force overrides the count guard" [ $rc -eq 0 ]
n_gens=$(ls -d "$GEN_BASE"/g.* "$GEN_BASE"/legacy.* 2>/dev/null | wc -l)
check "old generations pruned (current + previous kept: $n_gens)" [ "$n_gens" -le 2 ]

# wait_stable failure -> retry code (worker re-queues)
wait_stable() { return 1; }
regen; rc=$?
check "unstable httpd.conf returns retry code 75" [ $rc -eq 75 ]

# --- backstop -----------------------------------------------------------------
spawn_worker() { :; }
rm -f "$PENDING"
conf_hash > "$STATE_DIR/httpd.synced"
check_backstop
check "backstop: no queue when httpd.conf already synced" [ ! -e "$PENDING" ]
echo '# changed' >> "$T/httpd.conf"
check_backstop
check "backstop: queues when httpd.conf changed" [ -s "$PENDING" ]
rm -f "$PENDING"; conf_hash > "$STATE_DIR/httpd.failed"
check_backstop
check "backstop: does not loop on a known-bad httpd.conf" [ ! -e "$PENDING" ]

echo "passed $pass, failed $fail"
[ $fail -eq 0 ]
