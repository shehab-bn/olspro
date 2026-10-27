#!/usr/bin/env bash
#############################################################################
#    OLS PRO - end-to-end smoke test of a built openlitespeed binary.       #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
# Runs entirely under $SMOKE_ROOT (default /srv/olspro-smoke) on a build box.
#
#   S1  minimal server root, one listener 127.0.0.1:18080, one static vhost,
#       modbruteguard loaded:  GET / == 200 + body,  POST /wp-login.php x13
#       -> 1..10 not throttled, 11.. 429 + numeric Retry-After,
#       SIGTERM -> process gone, port closed, no orphans.
#   S2  apache2ols over pro/tests/apacheconf/fixtures, docroots/ports/certs
#       rewritten into the sandbox, `openlitespeed -t` then a real start and
#       GET / with Host: example.com (and https with a sandbox CA chain).
#
# Isolation from any real OLS/LSWS on the host:
#   * refuses to run while another openlitespeed/litespeed/lshttpd runs or a
#     host pid file (/tmp/lshttpd/lshttpd.pid, /var/run/openlitespeed.pid)
#     names a live server;
#   * OLS_PID_FILE points into the sandbox;
#   * tuning.shmDefaultDir points into the sandbox, so SHM pools (adns
#     cache, bruteguard "olsprobg") are fresh every run;
#   * when `unshare -m` works (root, default SMOKE_ISOLATE=auto) the server
#     runs in a private mount namespace with tmpfs over /tmp/lshttpd and
#     /dev/shm/ols and a sandbox file bound over /var/run/openlitespeed.pid.
#
# Env: OLS_SRC (/root/olspro)  OLS_BIN  SMOKE_ROOT (/srv/olspro-smoke)
#      RUN_USER / RUN_GROUP (nobody / nobody)  SMOKE_ISOLATE (auto|0|1)
# Exit code: number of failed checks (capped at 90); 97 = refused because a
#   real server is running; 98 = no failures but some checks were SKIPPED;
#   99 = setup error (no binary, bad SMOKE_ROOT, missing tools).
set -u

OLS_SRC=${OLS_SRC:-/root/olspro}
BIN=${OLS_BIN:-$OLS_SRC/build/src/openlitespeed}
BG_SO=$OLS_SRC/build/src/modules/modbruteguard/modbruteguard.so
BASE=${SMOKE_ROOT:-/srv/olspro-smoke}
BASE=${BASE%/}
RUN_USER=${RUN_USER:-nobody}
RUN_GROUP=${RUN_GROUP:-nobody}
ISOLATE=${SMOKE_ISOLATE:-auto}
BG_LIMIT=10
CURL=(curl -s --max-time 5)
SRV_NAMES='openlitespeed|litespeed|lshttpd'
FAILS=0
SKIPS=0
PID=
KIDS=
PORTS=

pass() { echo "PASS  $*"; }
fail() { echo "FAIL  $*"; FAILS=$((FAILS + 1)); }
skip() { echo "SKIP  $*"; SKIPS=$((SKIPS + 1)); }
die()  { echo "ABORT $*"; exit 99; }

#############################################################################
# preflight

case "$BASE" in
    /*) ;;
    *) die "SMOKE_ROOT must be an absolute path (got '$BASE')" ;;
esac
case "$BASE" in
    ""|/|/root|/home|/srv|/usr|/usr/local|/usr/local/lsws|/var|/etc|/tmp|/opt)
        die "refusing SMOKE_ROOT=$BASE (too broad, s1/s2 under it are rm -rf'd)" ;;
esac
for t in curl ss pgrep su; do
    command -v "$t" >/dev/null 2>&1 || die "'$t' is required (ss: iproute2, pgrep: procps)"
done
[ -x "$BIN" ] || die "no binary at $BIN"

# A live OLS/LSWS shares /tmp/lshttpd, /var/run/openlitespeed.pid and
# /dev/shm/ols with us; never run next to one.
isServerPid()
{
    local p=$1
    [ -n "$p" ] && [ -d "/proc/$p" ] || return 1
    grep -qxE "$SRV_NAMES" "/proc/$p/comm" 2>/dev/null && return 0
    tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -qiE 'lshttpd|litespeed'
}
others=$(pgrep -x "$SRV_NAMES" 2>/dev/null | tr '\n' ' ')
if [ -n "$others" ]; then
    echo "REFUSE another OpenLiteSpeed/LiteSpeed process is running (pids: $others)."
    echo "       The smoke would share /tmp/lshttpd, /var/run/openlitespeed.pid and SHM with it."
    exit 97
fi
for pf in /tmp/lshttpd/lshttpd.pid /var/run/openlitespeed.pid; do
    p=$(tr -dc '0-9' <"$pf" 2>/dev/null)
    if isServerPid "$p"; then
        echo "REFUSE $pf names live server pid $p"
        exit 97
    fi
done

echo "binary: $("$BIN" -v 2>&1 | head -n 1)"
mkdir -p "$BASE" || die "cannot create $BASE"
chmod a+rx "$BASE"

# Private mount namespace for /tmp/lshttpd, /dev/shm/ols, /var/run pid file.
if [ "$ISOLATE" = auto ]; then
    ISOLATE=0
    mkdir -p "$BASE/.nsprobe"
    if [ "$(id -u)" = 0 ] \
        && unshare -m -- mount -t tmpfs olsprosmoke "$BASE/.nsprobe" 2>/dev/null; then
        ISOLATE=1
    fi
    rmdir "$BASE/.nsprobe" 2>/dev/null
fi
if [ "$ISOLATE" = 1 ]; then
    echo "isolation: private mount namespace (tmpfs /tmp/lshttpd, /dev/shm/ols)"
else
    echo "NOTE  no mount namespace: /tmp/lshttpd and /var/run/openlitespeed.pid are the host's"
fi
# $1 = server root, rest = command. Runs inside `unshare -m`; mounts are
# private to the namespace and vanish with the server.
NS_SH='sr=$1; shift
mkdir -p /tmp/lshttpd /dev/shm/ols || exit 120
mount -t tmpfs -o mode=0755 olsprosmoke /tmp/lshttpd || exit 121
mount -t tmpfs -o mode=0755 olsprosmoke /dev/shm/ols || exit 122
if [ -e /var/run/openlitespeed.pid ]; then
    : >"$sr/tmp/varrun.pid" && mount --bind "$sr/tmp/varrun.pid" /var/run/openlitespeed.pid || exit 123
fi
exec "$@"'

# Sets CMD to the server command line for server root $1 (append args).
olsCmd()
{
    local sr=$1
    CMD=(env -u OLSPRO_BG_OFF LSWS_HOME="$sr" OLS_PID_FILE="$sr/tmp/lshttpd.pid"
         OLSPRO_BG_LIMIT=$BG_LIMIT OLSPRO_BG_WINDOW=60 OLSPRO_BG_BAN=300 "$BIN")
    if [ "$ISOLATE" = 1 ]; then
        CMD=(unshare -m -- /bin/sh -c "$NS_SH" olsns "$sr" "${CMD[@]}")
    fi
}

# The server drops to $RUN_USER; it must be able to reach the docroots.
TRAVERSE=1
if ! su -s /bin/sh "$RUN_USER" -c "test -x '$BASE'" 2>/dev/null; then
    TRAVERSE=0
    echo "NOTE  $RUN_USER cannot traverse $BASE (parent mode $(stat -c %a "$(dirname "$BASE")")); docroot checks will be SKIPPED"
fi

#############################################################################
# helpers

mkroot()
{
    local sr=$1
    rm -rf "$sr"
    mkdir -p "$sr"/conf/vhosts "$sr"/logs "$sr"/tmp/swap "$sr"/modules "$sr"/shm
    chown "$RUN_USER:$RUN_GROUP" "$sr"/shm "$sr"/tmp/swap 2>/dev/null
    chmod 0750 "$sr"/shm
    cp "$OLS_SRC"/dist/conf/mime.properties "$sr"/conf/
    # a real install ships share/autoindex; vhosts reference it at load time
    cp -a "$OLS_SRC"/dist/share "$sr"/ 2>/dev/null
}

# server-level part shared by both scenarios
serverHead()
{
    local sr=$1
    cat <<EOF
serverName                smoke
user                      $RUN_USER
group                     $RUN_GROUP
autoRestart               0
inMemBufSize              8M
swappingDir               $sr/tmp/swap
mime                      conf/mime.properties
indexFiles                index.html
disableWebAdmin           1
httpdWorkers              1

tuning {
  shmDefaultDir           $sr/shm/
}

# Same values the shipped dist/conf/httpd_config.conf.in uses. Without this
# block OLS falls back to restrictedPermissionMask 041111, which trips an
# upstream bug: GET / with a single-entry indexFiles list returns 403 (the
# directory's mode is checked instead of index.html's). See ROADMAP "Known
# upstream bugs".
fileAccessControl {
  followSymbolLink        1
  checkSymbolLink         0
  requiredPermissionMask  000
  restrictedPermissionMask 000
}

errorlog $sr/logs/error.log {
  logLevel                DEBUG
  debugLevel              0
  enableStderrLog         1
}

accessLog $sr/logs/access.log {
}
EOF
}

portOpen()
{
    ss -ltnH 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {f=1} END {exit !f}'
}

# All live descendants of $1.
descendants()
{
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do
        echo "$c"
        descendants "$c"
    done
}

# Live processes that belong to server root $1: recorded descendants, plus
# any server-named process whose environment carries LSWS_HOME=$1.
ourProcs()
{
    local sr=$1 p
    for p in $KIDS $(pgrep -x "$SRV_NAMES" 2>/dev/null); do
        [ -d "/proc/$p" ] || continue
        case " $KIDS " in *" $p "*) echo "$p"; continue ;; esac
        tr '\0' '\n' <"/proc/$p/environ" 2>/dev/null | grep -qxF "LSWS_HOME=$sr" && echo "$p"
    done | sort -u | tr '\n' ' '
}

waitPort()
{
    local port=$1 i
    for i in $(seq 1 50); do
        kill -0 "$PID" 2>/dev/null || return 1
        "${CURL[@]}" -o /dev/null --max-time 1 "http://127.0.0.1:$port/" && return 0
        sleep 0.2
    done
    return 1
}

confTest()
{
    local sr=$1 tag=$2 rc
    olsCmd "$sr"
    "${CMD[@]}" -t >"$sr"/logs/conftest.log 2>&1
    rc=$?
    grep -E 'ERROR|WARN|CRIT|\[config' "$sr"/logs/conftest.log | head -n 20 | sed 's/^/      /'
    if [ $rc = 0 ]; then
        pass "$tag openlitespeed -t"
    else
        fail "$tag openlitespeed -t exit=$rc"
    fi
}

# start <server root> <http port probed> [other ports it will bind...]
start()
{
    local sr=$1 port=$2 p busy=""
    PID= KIDS= PORTS="$*"
    PORTS=${PORTS#"$sr" }
    if [ ! -f "$sr/conf/httpd_config.conf" ] || [ ! -s "$sr/conf/httpd_config.conf" ]; then
        # OLS would silently fall back to /usr/local/lsws (guessCommonServerRoot).
        fail "no config at $sr/conf/httpd_config.conf, not starting"
        return 1
    fi
    for p in $PORTS; do portOpen "$p" && busy="$busy $p"; done
    if [ -n "$busy" ]; then
        busy=${busy# }
        fail "port(s) $busy already in use before start: $(ss -ltnpH 2>/dev/null | grep -E ":(${busy// /|})\b" | tr -s ' ' | head -n 3)"
        return 1
    fi
    olsCmd "$sr"
    "${CMD[@]}" -d >"$sr"/logs/stdout.log 2>&1 &
    PID=$!
    if waitPort "$port" && kill -0 "$PID" 2>/dev/null; then
        KIDS=$(descendants "$PID" | tr '\n' ' ')
        pass "server up on :$port (pid $PID)"
        return 0
    fi
    fail "server did not come up on :$port"
    echo "---- $sr/logs/stdout.log (tail)"; tail -n 25 "$sr"/logs/stdout.log
    echo "---- $sr/logs/error.log (ERROR/WARN)"
    grep -E 'ERROR|WARN|CRIT' "$sr"/logs/error.log 2>/dev/null | tail -n 25
    stop "$sr" quiet
    return 1
}

# stop <server root> [quiet]
stop()
{
    local sr=$1 mode=${2:-} i st left p
    [ -n "$PID" ] || return 0
    if ! kill -0 "$PID" 2>/dev/null; then
        wait "$PID" 2>/dev/null
        st=$?
        if [ "$mode" = quiet ]; then
            echo "      pid $PID exited early (exit/signal status $st)"
        else
            fail "pid $PID died before stop (exit/signal status $st)"
        fi
    else
        kill -TERM "$PID" 2>/dev/null
        for i in $(seq 1 50); do
            kill -0 "$PID" 2>/dev/null || break
            sleep 0.2
        done
        if kill -0 "$PID" 2>/dev/null; then
            [ "$mode" = quiet ] || fail "pid $PID still alive 10s after SIGTERM"
            kill -KILL "$PID" 2>/dev/null
            for i in $(seq 1 25); do
                kill -0 "$PID" 2>/dev/null || break
                sleep 0.2
            done
        else
            [ "$mode" = quiet ] || pass "clean stop after SIGTERM"
        fi
        wait "$PID" 2>/dev/null
    fi
    # Orphans and listeners are checked on every path, quiet or not.
    sleep 0.2
    left=$(ourProcs "$sr")
    if [ -n "${left// /}" ]; then
        fail "process(es) of $sr outlived the server: $left"
        kill -KILL $left 2>/dev/null
    fi
    for p in $PORTS; do
        for i in $(seq 1 25); do
            portOpen "$p" || break
            sleep 0.2
        done
        portOpen "$p" && fail "listener :$p still open after stop"
    done
    # Without a mount namespace (or when it did not exist before) OLS wrote
    # the host's /var/run/openlitespeed.pid; remove it if it is ours.
    [ "$(tr -dc '0-9' </var/run/openlitespeed.pid 2>/dev/null)" = "$PID" ] \
        && rm -f /var/run/openlitespeed.pid
    PID= KIDS= PORTS=
}

#############################################################################
echo "== S1: static vhost + modbruteguard"
S1=$BASE/s1
mkroot "$S1"
mkdir -p "$S1"/vh/html "$S1"/conf/vhosts/smoke
echo "olspro-smoke-ok" >"$S1"/vh/html/index.html
if [ -f "$BG_SO" ]; then
    cp "$BG_SO" "$S1"/modules/modbruteguard.so
    stale=""
    for s in "$OLS_SRC"/src/modules/modbruteguard/modbruteguard.cpp "$OLS_SRC"/include/ls.h; do
        [ "$s" -nt "$BG_SO" ] && stale="$stale ${s#"$OLS_SRC"/}"
    done
    if [ -z "$stale" ]; then
        pass "modbruteguard.so is newer than its sources"
    else
        fail "modbruteguard.so is older than:$stale (rebuild it; S1 results describe stale code)"
    fi
else
    fail "missing $BG_SO"
fi
{
    serverHead "$S1"
    cat <<EOF

module modbruteguard {
  ls_enabled              1
}

virtualHost smoke {
  vhRoot                  $S1/vh/
  configFile              conf/vhosts/smoke/vhconf.conf
  allowSymbolLink         1
  enableScript            0
  restrained              1
}

listener smoke {
  address                 127.0.0.1:18080
  secure                  0
  map                     smoke *
}
EOF
} >"$S1"/conf/httpd_config.conf
cat >"$S1"/conf/vhosts/smoke/vhconf.conf <<'EOF'
docRoot                   $VH_ROOT/html/
index  {
  useServer               0
  indexFiles              index.html
}
EOF
chmod -R a+rX "$S1"
# cPanel docroots belong to the account (uid >= 1000); root-owned ones make
# OLS warn "Uid ... smaller than minimum requirement" and -t exit 1.
chown -R 1000:1000 "$S1"/vh
chmod 0750 "$S1"/shm

confTest "$S1" S1
if start "$S1" 18080; then
    body=$("${CURL[@]}" -w '\n%{http_code}' http://127.0.0.1:18080/)
    code=${body##*$'\n'}
    if [ "$TRAVERSE" = 0 ]; then
        skip "GET / -> 200 ($RUN_USER cannot reach $BASE; got $code)"
    elif [ "$code" = 200 ] && echo "$body" | grep -q olspro-smoke-ok; then
        pass "GET / -> 200 with body"
    else
        fail "GET / -> $code body=[$(echo "$body" | head -n 1)]"
    fi

    # Fresh SHM (sandbox shmDefaultDir), so the first BG_LIMIT POSTs must
    # pass and request BG_LIMIT+1 must be the first 429.
    seq="" early="" dead="" c11="" ra=""
    for i in $(seq 1 $((BG_LIMIT + 3))); do
        h=$("${CURL[@]}" -D - -o /dev/null -X POST -d 'log=a&pwd=b' \
            http://127.0.0.1:18080/wp-login.php)
        c=$(printf '%s\n' "$h" | head -n 1 | awk '{print $2}')
        c=${c:-000}
        seq="$seq $c"
        [ "$c" = 000 ] && dead="$dead #$i"
        [ "$i" -le "$BG_LIMIT" ] && [ "$c" = 429 ] && early="$early #$i"
        if [ "$i" = $((BG_LIMIT + 1)) ]; then
            c11=$c
            ra=$(printf '%s\n' "$h" | tr -d '\r' \
                | awk -F': *' 'tolower($1)=="retry-after"{print $2; exit}')
        fi
    done
    echo "      wp-login status sequence:$seq"
    if [ -n "$dead" ]; then
        fail "bruteguard: no response for request(s)$dead (worker crash?)"
    fi
    if [ -n "$early" ]; then
        fail "bruteguard: throttled before the limit of $BG_LIMIT:$early"
    else
        pass "bruteguard: POSTs 1..$BG_LIMIT not throttled"
    fi
    if [ "$c11" = 429 ] && [[ "$ra" =~ ^[0-9]+$ ]]; then
        pass "bruteguard: POST #$((BG_LIMIT + 1)) -> 429, Retry-After: $ra"
    else
        fail "bruteguard: POST #$((BG_LIMIT + 1)) -> '$c11', Retry-After='$ra' (want 429 + number)"
    fi
    if grep -qE 'exited with status=[1-9]|SIGSEGV|[Ss]egmentation fault|signal 11' \
            "$S1"/logs/error.log "$S1"/logs/stdout.log 2>/dev/null; then
        fail "crash logged during S1: $(grep -hE 'exited with status=[1-9]|SIGSEGV|[Ss]egmentation fault|signal 11' "$S1"/logs/error.log "$S1"/logs/stdout.log | head -n 2)"
    fi
    c=$("${CURL[@]}" -o /dev/null -w '%{http_code}' http://127.0.0.1:18080/)
    if [ "$TRAVERSE" = 0 ]; then
        skip "GET / still 200 while banned on login path (got $c)"
    elif [ "$c" = 200 ]; then
        pass "GET / still 200 while client banned on login path"
    else
        fail "GET / -> $c after login ban (want 200)"
    fi
    ls "$S1"/shm/olsprobg.* >/dev/null 2>&1 \
        && echo "      bruteguard SHM pool in sandbox: $(ls "$S1"/shm/olsprobg.* | tr '\n' ' ')" \
        || echo "      NOTE no olsprobg pool in $S1/shm (module used per-process fallback?)"
    stop "$S1"
fi

#############################################################################
echo "== S2: apache2ols fixtures -> OLS"
S2=$BASE/s2
FIX=$OLS_SRC/pro/tests/apacheconf/fixtures
A2O=$BASE/apache2ols
SSLD=$S2/ssl
mkroot "$S2"
S2OK=1
if g++ -std=gnu++17 -O0 -o "$A2O" "$OLS_SRC"/pro/tools/apache2ols.cpp \
        "$OLS_SRC"/src/main/apacheconf.cpp -I"$OLS_SRC"/src/main -I"$OLS_SRC"/src; then
    pass "apache2ols compiled"
else
    fail "apache2ols compile"
    S2OK=0
fi
if [ $S2OK = 1 ]; then
    "$A2O" --root "$FIX" --warnings --out "$S2"/gen "$FIX"/httpd.conf 2>&1 | sed 's/^/      /'
    rc=${PIPESTATUS[0]}
    if [ "$rc" = 0 ] && [ -s "$S2"/gen/olspro_apache.conf ]; then
        pass "apache2ols convert"
    else
        fail "apache2ols convert exit=$rc (olspro_apache.conf $( [ -s "$S2"/gen/olspro_apache.conf ] && echo present || echo missing))"
        S2OK=0
    fi
fi

# TLS material: a sandbox CA and a leaf for example.com signed by it, so the
# generated certChain 1 is exercised with a real cert+chain bundle.
if [ $S2OK = 1 ]; then
    mkdir -p "$SSLD"
    printf 'subjectAltName=DNS:example.com,DNS:www.example.com\nbasicConstraints=CA:FALSE\n' \
        >"$SSLD"/leaf.ext
    if openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj /CN=olspro-smoke-ca \
            -addext basicConstraints=critical,CA:TRUE \
            -addext keyUsage=critical,keyCertSign,cRLSign \
            -keyout "$SSLD"/ca.key -out "$SSLD"/ca.pem >/dev/null 2>&1 \
        && openssl req -newkey rsa:2048 -nodes -subj /CN=example.com \
            -keyout "$SSLD"/key.pem -out "$SSLD"/leaf.csr >/dev/null 2>&1 \
        && openssl x509 -req -in "$SSLD"/leaf.csr -CA "$SSLD"/ca.pem -CAkey "$SSLD"/ca.key \
            -CAcreateserial -days 2 -extfile "$SSLD"/leaf.ext -out "$SSLD"/leaf.pem >/dev/null 2>&1
    then
        cat "$SSLD"/leaf.pem "$SSLD"/ca.pem >"$SSLD"/fullchain.pem
    else
        fail "could not create sandbox TLS material"
        S2OK=0
    fi
fi

if [ $S2OK = 0 ]; then
    skip "S2 server checks (converter or TLS setup failed)"
else
    # Sandbox the generated config: docroots, logs, ports, TLS material.
    # certChain stays as generated; certFile is a leaf+CA bundle.
    SED_TLS=(-e "s#\(keyFile *\).*#\1$SSLD/key.pem#"
             -e "s#\(certFile *\).*#\1$SSLD/fullchain.pem#"
             -e "s#\(CACertFile *\).*#\1$SSLD/ca.pem#"
             -e "s#\(CACertPath *\).*#\1$SSLD/#")
    SED_PATHS=(-e "s#/home/exuser/public_html#$S2/docroots/exuser/public_html#g"
               -e "s#/usr/local/apache/htdocs#$S2/docroots/htdocs#g")
    mkdir -p "$S2"/docroots/exuser/public_html "$S2"/docroots/htdocs
    echo "example-com-ok" >"$S2"/docroots/exuser/public_html/index.html
    echo "cpanel-proxy-docroot" >"$S2"/docroots/htdocs/index.html
    sed -i "${SED_PATHS[@]}" "${SED_TLS[@]}" \
        -e "s#\(address *\)\(\*\|\[ANY\]\|[0-9.]*\):80\$#\1127.0.0.1:18081#" \
        -e "s#\(address *\)\(\*\|\[ANY\]\|[0-9.]*\):443\$#\1127.0.0.1:18443#" \
        -e "s#^\( *configFile *\)vhosts/#\1$S2/gen/vhosts/#" \
        "$S2"/gen/olspro_apache.conf
    find "$S2"/gen/vhosts -name vhconf.conf -exec sed -i "${SED_PATHS[@]}" "${SED_TLS[@]}" \
        -e "s#/var/log/apache2/domlogs/#$S2/logs/#g" {} \;
    {
        serverHead "$S2"
        echo
        cat "$S2"/gen/olspro_apache.conf
    } >"$S2"/conf/httpd_config.conf
    chmod -R a+rX "$S2"
    chown -R 1000:1000 "$S2"/docroots
    chmod 0750 "$S2"/shm
    chmod 0600 "$SSLD"/ca.key
    echo "---- generated listeners after sandboxing"
    grep -A4 '^listener' "$S2"/conf/httpd_config.conf | sed 's/^/      /'
    left=$(grep -rhoE '/(home|usr/local/apache|var/cpanel|etc/ssl|etc/apache2|etc/httpd)/[^ ]*' \
        "$S2"/conf/httpd_config.conf "$S2"/gen/vhosts 2>/dev/null | sort -u | head -n 5)
    [ -z "$left" ] || echo "      NOTE host paths left after sandboxing: $(echo "$left" | tr '\n' ' ')"

    echo "---- openlitespeed -t"
    confTest "$S2" S2

    if start "$S2" 18081 18443; then
        for host in example.com www.example.com cpanel.example.com; do
            r=$("${CURL[@]}" -w ' %{http_code}' -H "Host: $host" http://127.0.0.1:18081/)
            echo "      Host: $host -> $r"
        done
        r=$("${CURL[@]}" -w ' %{http_code}' -H "Host: example.com" http://127.0.0.1:18081/)
        if [ "$TRAVERSE" = 0 ]; then
            skip "Host: example.com served ($RUN_USER cannot reach $BASE; got [$r])"
        else
            case "$r" in
                *example-com-ok*" 200") pass "Host: example.com served from converted vhost" ;;
                *" 301")
                    pass "Host: example.com -> 301 (fixture forces https)"
                    t=$("${CURL[@]}" --cacert "$SSLD"/ca.pem -w ' %{http_code}' \
                        --resolve example.com:18443:127.0.0.1 https://example.com:18443/)
                    case "$t" in
                        *example-com-ok*" 200") pass "https://example.com:18443/ -> 200, cert verifies against sandbox CA" ;;
                        *) fail "https example.com not served: [$(echo "$t" | tail -c 80)]" ;;
                    esac ;;
                *) fail "Host: example.com -> [$r]" ;;
            esac
        fi
        grep -E 'ERROR|CRIT' "$S2"/logs/error.log | head -n 15 | sed 's/^/      log: /'
        stop "$S2"
    fi
fi

echo "== smoke done: $FAILS failure(s), $SKIPS skipped"
[ "$FAILS" -gt 90 ] && FAILS=90
[ "$FAILS" -gt 0 ] && exit "$FAILS"
[ "$SKIPS" -gt 0 ] && exit 98
exit 0
