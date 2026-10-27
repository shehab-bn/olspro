#!/usr/bin/env bash
#############################################################################
#    OLS PRO - CPNS (ToshostCP) pre-reload config validator.                #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
#
# Read-only. Validates the OpenLiteSpeed config that CPNS generates
# (conf/httpd_config.conf -> include toshostcp_vhosts.conf -> per-vhost
# conf/vhosts/<domain>/vhconf.conf) BEFORE CPNS runs `lswsctrl reload`.
# Prints one JSON document on stdout. Never writes, never reloads.
#
# Usage: olspro-cpns-check.sh [--root DIR] [--no-config-test]
#                             [--warn-days N] [--strict]
#   --root DIR         LSWS/OLS server root (default /usr/local/lsws or $LSWS_ROOT)
#   --no-config-test   skip `bin/openlitespeed -t`
#   --warn-days N      warn when a cert expires within N days (default 14)
#   --strict           warnings also make the exit code non-zero
# Exit: 0 = no failures, 1 = at least one failure (or warning with --strict),
#       2 = usage error / server root unusable (JSON is still printed).
# Needs bash >= 4.0 (associative arrays); written to be safe on 4.2 (EL7).

set -u
export LC_ALL=C

ROOT="${LSWS_ROOT:-/usr/local/lsws}"
DO_CONFTEST=1
WARN_DAYS=14
STRICT=0
MANAGED_INCLUDE="toshostcp_vhosts.conf"
OLS_TMP_DIR="/tmp/lshttpd"      # DEFAULT_TMP_DIR: OLS mkdirs it on start
US=$'\037'                      # field separator for internal records

# ---------------------------------------------------------------- output ---
RESULTS=()
N_OK=0; N_WARN=0; N_FAIL=0; N_SKIP=0
_J=""

# jesc <string>: JSON-quote into $_J without forking (tr only runs when a
# stray control character is actually present).
jesc()
{
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    case "$s" in
        *[[:cntrl:]]*) s="$(printf '%s' "$s" | tr -d '\000-\037')" ;;
    esac
    _J="\"$s\""
}

usage_err()
{
    jesc "$1"
    printf '{"ok":false,"tool":"olspro-cpns-check","version":1,"error":%s}\n' "$_J"
    exit 2
}

while [ $# -gt 0 ]; do
    case "$1" in
        --root) [ $# -ge 2 ] || usage_err "--root needs a value"
                ROOT="$2"; shift 2 ;;
        --root=*) ROOT="${1#*=}"; shift ;;
        --no-config-test) DO_CONFTEST=0; shift ;;
        --warn-days) [ $# -ge 2 ] || usage_err "--warn-days needs a value"
                     WARN_DAYS="$2"; shift 2 ;;
        --warn-days=*) WARN_DAYS="${1#*=}"; shift ;;
        --strict) STRICT=1; shift ;;
        -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
        *) usage_err "unknown argument: $1" ;;
    esac
done
case "$WARN_DAYS" in ''|*[!0-9]*) WARN_DAYS=14 ;; esac
[ -n "$ROOT" ] || usage_err "--root is empty"
ROOT="${ROOT%/}"

# add <status ok|warn|fail|skip> <check> <target> <detail>
add()
{
    case "$1" in
        ok) N_OK=$((N_OK + 1)) ;;
        warn) N_WARN=$((N_WARN + 1)) ;;
        fail) N_FAIL=$((N_FAIL + 1)) ;;
        skip) N_SKIP=$((N_SKIP + 1)) ;;
    esac
    local c t d
    jesc "$2"; c="$_J"
    jesc "$3"; t="$_J"
    jesc "$4"; d="$_J"
    RESULTS+=("{\"status\":\"$1\",\"check\":$c,\"target\":$t,\"detail\":$d}")
}

# finish [exit-code override]
finish()
{
    local ok=true rc=0 jr
    if [ "$N_FAIL" -gt 0 ] || { [ "$STRICT" -eq 1 ] && [ "$N_WARN" -gt 0 ]; }; then
        ok=false; rc=1
    fi
    if [ $# -gt 0 ]; then ok=false; rc="$1"; fi
    jesc "$ROOT"; jr="$_J"
    local IFS=,
    printf '{"ok":%s,"tool":"olspro-cpns-check","version":1,"root":%s,"generated":"%s",' \
        "$ok" "$jr" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '"summary":{"ok":%d,"warn":%d,"fail":%d,"skip":%d},"checks":[%s]}\n' \
        "$N_OK" "$N_WARN" "$N_FAIL" "$N_SKIP" "${RESULTS[*]-}"
    exit "$rc"
}

# ---------------------------------------------------------------- parser ---
# flatten <file>: print "blockpath<TAB>key<TAB>value" for every directive.
# Blocks "name arg {" become "name:arg"; nesting is joined with "/".
# Multi-line "<<<END_x ... END_x" values are skipped (rewrite rules etc).
# The "include" keyword is matched case-insensitively, as OLS does.
flatten()
{
    awk '
    BEGIN { depth = 0; heredoc = "" }
    {
        line = $0
        if (heredoc != "") {
            t = line; gsub(/^[ \t]+|[ \t]+$/, "", t)
            if (t == heredoc) heredoc = ""
            next
        }
        sub(/^[ \t]+/, "", line)
        if (substr(line, 1, 1) == "#") next
        sub(/[ \t]+$/, "", line)
        if (line == "") next
        if (match(line, /<<<[A-Za-z0-9_]+$/)) {
            heredoc = substr(line, RSTART + 3)
            next
        }
        if (line == "}") { if (depth > 0) depth--; next }
        if (line ~ /\{$/) {
            hdr = line; sub(/[ \t]*\{$/, "", hdr)
            n = split(hdr, a, /[ \t]+/)
            depth++
            stack[depth] = (n > 1) ? a[1] ":" a[2] : a[1]
            next
        }
        key = line; sub(/[ \t].*$/, "", key)
        if (tolower(key) == "include") key = "include"
        val = line; sub(/^[^ \t]+[ \t]*/, "", val)
        path = ""
        for (i = 1; i <= depth; i++) path = path (i > 1 ? "/" : "") stack[i]
        printf "%s\t%s\t%s\n", path, key, val
    }' "$1" 2>/dev/null
}

_X=""
# expand <value> <vh_root> <vh_name> <doc_root>: resolve OLS variables in a
# directive value and make relative paths absolute against the server root.
# Result in $_X.
expand()
{
    local v="$1"
    v="${v//\$SERVER_ROOT/$ROOT}"
    v="${v//\$VH_ROOT/${2%/}}"
    v="${v//\$VH_NAME/$3}"
    v="${v//\$DOC_ROOT/${4%/}}"
    v="${v//\/\//\/}"
    case "$v" in /*) ;; *) v="$ROOT/$v" ;; esac
    _X="$v"
}

_P=""
# resolve_include <dir of including file> <include arg>: mirror
# plainconf::getIncludeFile(). Absolute paths stay; "$server_root/" (any
# case) maps to the server root; any other "$VAR" cannot be resolved (OLS
# logs "Can't resolve include file" and drops it); everything else is
# relative to the including file's directory. Result in $_P; returns 1 when
# OLS would not resolve it.
resolve_include()
{
    local cur="$1" f="$2" head
    _P=""
    [ -n "$f" ] || return 1
    case "$f" in
        /*) _P="$f" ;;
        \$*)
            head="${f:0:13}"
            [ "${head,,}" = '$server_root/' ] || return 1
            _P="$ROOT/${f:13}"
            ;;
        *) _P="$cur/$f" ;;
    esac
    while :; do
        case "$_P" in
            *//*) _P="${_P//\/\//\/}" ;;
            */./*) _P="${_P//\/.\//\/}" ;;
            *) break ;;
        esac
    done
    return 0
}

# ----------------------------------------------------------------- certs ---
declare -A CERT_C=()
declare -A KEY_C=()
HAVE_OPENSSL=0
command -v openssl >/dev/null 2>&1 && HAVE_OPENSSL=1

check_cert()  # <scope> <certFile> <keyFile>
{
    local scope="$1" cert="$2" key="$3" kpub="" rec st end cpub
    if [ -n "$key" ]; then
        if [ ! -r "$key" ]; then
            add fail ssl.key "$key" "$scope: key file missing or unreadable"
        elif [ "$HAVE_OPENSSL" -eq 1 ]; then
            if [ -z "${KEY_C[$key]+x}" ]; then
                # -passin pass: + </dev/null: never prompt on a tty for an
                # encrypted key (OLS cannot load one unattended anyway).
                KEY_C[$key]="$(openssl pkey -in "$key" -pubout -passin pass: </dev/null 2>/dev/null)"
            fi
            kpub="${KEY_C[$key]}"
            case "$kpub" in
                *"BEGIN PUBLIC KEY"*) add ok ssl.key "$key" "$scope: key readable" ;;
                *) kpub=""
                   add fail ssl.key "$key" "$scope: key cannot be parsed (corrupt, unsupported or passphrase-protected)" ;;
            esac
        else
            add ok ssl.key "$key" "$scope: key readable (openssl missing, not parsed)"
        fi
    fi
    [ -n "$cert" ] || return 0
    if [ ! -r "$cert" ]; then
        add fail ssl.cert "$cert" "$scope: certificate missing or unreadable"
        return 0
    fi
    if [ "$HAVE_OPENSSL" -eq 0 ]; then
        add skip ssl.cert "$cert" "$scope: openssl not installed, expiry not checked"
        return 0
    fi
    # one cert is often shared by a listener and its vhost: cache the result
    if [ -z "${CERT_C[$cert]+x}" ]; then
        end="$(openssl x509 -in "$cert" -noout -enddate </dev/null 2>/dev/null)"
        end="${end#notAfter=}"
        cpub=""
        if [ -z "$end" ]; then
            st=bad
        elif ! openssl x509 -in "$cert" -noout -checkend 0 </dev/null >/dev/null 2>&1; then
            st=expired
        elif ! openssl x509 -in "$cert" -noout -checkend $((WARN_DAYS * 86400)) </dev/null >/dev/null 2>&1; then
            st=soon
        else
            st=ok
        fi
        if [ "$st" != bad ]; then
            cpub="$(openssl x509 -in "$cert" -noout -pubkey </dev/null 2>/dev/null)"
        fi
        CERT_C[$cert]="$st$US$end$US$cpub"
    fi
    rec="${CERT_C[$cert]}"
    st="${rec%%"$US"*}"; rec="${rec#*"$US"}"
    end="${rec%%"$US"*}"; cpub="${rec#*"$US"}"
    case "$st" in
        bad) add fail ssl.cert "$cert" "$scope: not a parseable PEM certificate"; return 0 ;;
        expired) add fail ssl.cert "$cert" "$scope: EXPIRED (notAfter $end)" ;;
        soon) add warn ssl.cert "$cert" "$scope: expires within $WARN_DAYS days (notAfter $end)" ;;
        *) add ok ssl.cert "$cert" "$scope: valid until $end" ;;
    esac
    # key/cert pair match (RSA/EC alike: compare SPKI public keys directly)
    case "$cpub" in *"BEGIN PUBLIC KEY"*) ;; *) cpub="" ;; esac
    if [ -n "$kpub" ] && [ -n "$cpub" ] && [ "$kpub" != "$cpub" ]; then
        add fail ssl.pair "$cert" "$scope: certificate does not match key $key"
    fi
}

# ---------------------------------------------------------- extprocessors ---
declare -A USER_C=()

# check_extprocs <flat> <scope> <sev> <vh_root> <vh_name> <doc_root>
# <sev> is the status used for problems: "fail" for vhost-level processors,
# "warn" for server-level ones (CPNS vhosts carry their own handler; the
# server-level lsphp only serves vhosts without one).
check_extprocs()
{
    local flat="$1" scope="$2" sev="$3" vr="$4" vn="$5" dra="$6"
    local ep addr epath euser auto sock sdir bin_only t
    while IFS="$US" read -r ep addr epath euser auto; do
        [ -n "$ep" ] || continue
        t="$scope/$ep"
        case "$addr" in
            uds://*)
                sock="/${addr#uds://}"; sock="${sock//\/\//\/}"
                sdir="${sock%/*}"; [ -n "$sdir" ] || sdir="/"
                if [ -S "$sock" ]; then
                    add ok extproc.socket "$t" "$sock"
                elif [ ! -d "$sdir" ]; then
                    if [ "$sdir" = "$OLS_TMP_DIR" ]; then
                        # Not fatal: lshttpd mkdirs it on (re)start, and a
                        # hard fail here would block the restart that fixes it.
                        add warn extproc.socket "$t" "socket directory $sdir missing (OLS down or /tmp wiped); OLS recreates it on start, so restart rather than reload"
                    else
                        add "$sev" extproc.socket "$t" "socket directory $sdir does not exist"
                    fi
                elif [ -n "$auto" ] && [ "$auto" != "0" ]; then
                    add ok extproc.socket "$t" "$sock not present yet; autoStart $auto creates it on first request"
                else
                    add "$sev" extproc.socket "$t" "$sock missing and autoStart is off: nothing will create it"
                fi
                ;;
            '') add "$sev" extproc.address "$t" "no address" ;;
            *) add ok extproc.address "$t" "$addr (TCP, not checked)" ;;
        esac
        if [ -n "$epath" ]; then
            bin_only="${epath%% *}"
            expand "$bin_only" "$vr" "$vn" "$dra"
            if [ -x "$_X" ]; then add ok extproc.binary "$t" "$_X"
            else add "$sev" extproc.binary "$t" "path $_X missing or not executable"; fi
        elif [ -n "$auto" ] && [ "$auto" != "0" ]; then
            add "$sev" extproc.binary "$t" "autoStart set but no path"
        fi
        if [ -n "$euser" ]; then
            if [ -z "${USER_C[$euser]+x}" ]; then
                if id -u "$euser" >/dev/null 2>&1; then USER_C[$euser]=1; else USER_C[$euser]=0; fi
            fi
            if [ "${USER_C[$euser]}" = 1 ]; then add ok extproc.user "$t" "$euser"
            else add "$sev" extproc.user "$t" "extUser $euser does not exist"; fi
        fi
    done < <(printf '%s\n' "$flat" | awk -F'\t' -v US="$US" '
        $1 ~ /^extprocessor:[^\/]+$/ {
            n = $1; sub(/^extprocessor:/, "", n)
            if (!(n in seen)) { seen[n] = 1; order[++cnt] = n }
            if ($2 == "address"   && !(n in A)) A[n] = $3
            if ($2 == "path"      && !(n in P)) P[n] = $3
            if ($2 == "extUser"   && !(n in U)) U[n] = $3
            if ($2 == "autoStart" && !(n in S)) S[n] = $3
        }
        END { for (i = 1; i <= cnt; i++) { n = order[i]
              printf "%s%s%s%s%s%s%s%s%s\n", n, US, A[n], US, P[n], US, U[n], US, S[n] } }')
}

# ------------------------------------------------------------------ main ---
CONF_DIR="$ROOT/conf"
MAIN="$CONF_DIR/httpd_config.conf"
if [ ! -d "$ROOT" ] || [ ! -r "$MAIN" ]; then
    add fail server.root "$MAIN" "server root or httpd_config.conf not readable"
    finish 2
fi
add ok server.root "$MAIN" "readable"

INC="$CONF_DIR/$MANAGED_INCLUDE"
MAIN_FLAT="$(flatten "$MAIN")"
TOP_INCS="$(printf '%s\n' "$MAIN_FLAT" | awk -F'\t' '$1=="" && $2=="include" {print $3}')"

# 1. Top-level includes, resolved exactly as OLS does. The managed include
#    must be one of them. Server-level files = main + every resolved include
#    (one level deep, glob support).
FILES=("$MAIN")
wired=""; wrong=""; wrong_to=""
while IFS= read -r f; do
    [ -n "$f" ] || continue
    if ! resolve_include "$CONF_DIR" "$f"; then
        add fail include.file "$f" "OLS cannot resolve include '$f' (only absolute, relative or \$SERVER_ROOT/ paths); it is dropped"
        case "$f" in *"$MANAGED_INCLUDE"*) [ -n "$wrong" ] || { wrong="$f"; wrong_to="(unresolvable)"; } ;; esac
        continue
    fi
    p="$_P"
    if [ "$p" = "$INC" ]; then
        wired="$f"
    else
        case "$f" in *"$MANAGED_INCLUDE"*) [ -n "$wrong" ] || { wrong="$f"; wrong_to="$p"; } ;; esac
    fi
    case "$p" in
        *'*'*|*'?'*|*'['*']'*)
            # wildcard include: OLS loads whatever matches
            n_match=0
            shopt -s nullglob
            oldifs="$IFS"; IFS=
            for g in $p; do
                if [ -r "$g" ]; then FILES+=("$g"); n_match=$((n_match + 1))
                else add fail include.file "$g" "included from httpd_config.conf but unreadable"; fi
            done
            IFS="$oldifs"
            shopt -u nullglob
            [ "$n_match" -gt 0 ] || add warn include.file "$p" "wildcard include matches no file"
            ;;
        *)
            if [ -r "$p" ]; then FILES+=("$p")
            else add fail include.file "$p" "included from httpd_config.conf but missing or unreadable"; fi
            ;;
    esac
done <<< "$TOP_INCS"

if [ -n "$wired" ]; then
    add ok include.wired "$MAIN" "include $wired"
elif [ -n "$wrong" ]; then
    add fail include.wired "$MAIN" "include is '$wrong', which OLS resolves to $wrong_to, not $INC; use 'include $MANAGED_INCLUDE'"
else
    add fail include.wired "$MAIN" "no top-level 'include $MANAGED_INCLUDE' line: CPNS vhosts are not loaded"
fi
if [ -z "$wired" ] && [ ! -r "$INC" ]; then
    add fail include.file "$INC" "managed include missing or unreadable"
fi

# 2. openlitespeed -t (OLS has a real config-test flag: -t sets m_iConfTestMode).
BIN="$ROOT/bin/openlitespeed"
if [ "$DO_CONFTEST" -eq 0 ]; then
    add skip config.test "$BIN" "disabled by --no-config-test"
elif [ ! -x "$BIN" ]; then
    add skip config.test "$BIN" "binary not found or not executable"
else
    if command -v timeout >/dev/null 2>&1; then
        out="$(timeout 30 "$BIN" -t 2>&1)"; rc=$?
    else
        out="$("$BIN" -t 2>&1)"; rc=$?
    fi
    errs="$(printf '%s\n' "$out" | grep -F '[ERROR]' | head -5)"
    if [ "$rc" -eq 124 ] || [ "$rc" -ge 128 ]; then
        # timeout(1) returns 124; a signal death is 128+N. Never a pass.
        add fail config.test "$BIN" "config test timed out or was killed (exit $rc)${errs:+: $errs}"
    elif [ -n "$errs" ]; then
        add fail config.test "$BIN" "$errs"
    elif [ "$rc" -eq 0 ]; then
        add ok config.test "$BIN" "openlitespeed -t passed"
    elif printf '%s' "$out" | grep -Eq '\[(WARN|NOTICE|INFO|DEBUG)\]'; then
        # Same tolerance as CPNS TestConfig(): non-zero exit with only
        # warnings means OLS ran and judged the config fine.
        add ok config.test "$BIN" "exit $rc with warnings only"
    else
        add fail config.test "$BIN" "could not run -t (exit $rc): $(printf '%s' "$out" | head -c 300)"
    fi
fi

# 3. Server-level files: listeners, maps, vhost declarations, extprocessors.
declare -A PORT_OWNER=()   # "fam|host|port" -> listener
declare -A PORTS=()        # port -> 1
declare -A MAP_SEEN=()
VHOST_LIST=()

for f in "${FILES[@]}"; do
    flat="$(flatten "$f")"
    while IFS="$US" read -r typ a1 a2 a3 a4 a5; do
        case "$typ" in
        L)  # listener: name addr secure cert key
            l="$a1"; addr="$a2"
            if [ -z "$addr" ]; then
                add warn listener "$l" "no address in $f"
                continue
            fi
            case "$addr" in
                *:*) port="${addr##*:}"; host="${addr%:*}" ;;
                *) port="$addr"; host="" ;;
            esac
            # Address families are separate: OLS binds [ANY] with
            # IPV6_V6ONLY retry (coresocket.cpp), so *:443 + [ANY]:443 is
            # the normal dual-stack pair, not a collision.
            case "$host" in
                \[*\]) fam=6; h="${host#[}"; h="${h%]}"
                       case "${h^^}" in '*'|ANY|ALL|'::'|'') h='*' ;; esac ;;
                *)     fam=4; h="$host"
                       case "${h^^}" in '*'|ANY|ALL|'0.0.0.0'|'') h='*' ;; esac ;;
            esac
            conflict=""
            if [ "${#PORT_OWNER[@]}" -gt 0 ]; then
                for k in "${!PORT_OWNER[@]}"; do
                    kf="${k%%|*}"; kr="${k#*|}"; kh="${kr%|*}"; kp="${kr##*|}"
                    [ "$kp" = "$port" ] && [ "$kf" = "$fam" ] || continue
                    if [ "$kh" = "$h" ] || [ "$kh" = '*' ] || [ "$h" = '*' ]; then
                        conflict="${PORT_OWNER[$k]}"
                    fi
                done
            fi
            if [ -n "$conflict" ]; then
                add fail port.conflict "$addr" "listener $l collides with listener $conflict on IPv$fam port $port"
            else
                add ok port.unique "$addr" "listener $l (IPv$fam)"
            fi
            PORT_OWNER["$fam|$h|$port"]="$l"
            PORTS["$port"]=1
            if [ "$a3" = "1" ]; then
                if [ -z "$a4" ] || [ -z "$a5" ]; then
                    add fail ssl.listener "$l" "secure listener without certFile/keyFile"
                else
                    expand "$a4" "" "" ""; c="$_X"
                    expand "$a5" "" "" ""
                    check_cert "listener $l" "$c" "$_X"
                fi
            fi
            ;;
        M)  # map: listener vhost domains
            l="$a1"; mv="$a2"
            IFS=',' read -r -a names <<< "$a3"
            for n in ${names[@]+"${names[@]}"}; do
                n="${n//[[:space:]]/}"
                [ -n "$n" ] || continue
                if [ -n "${MAP_SEEN[$l|$n]:-}" ] && [ "${MAP_SEEN[$l|$n]}" != "$mv" ]; then
                    add warn map.duplicate "$n" "listener $l maps $n to both ${MAP_SEEN[$l|$n]} and $mv (first wins)"
                fi
                MAP_SEEN["$l|$n"]="$mv"
            done
            ;;
        V)  # virtualhost: name vhRoot configFile
            VHOST_LIST+=("$a1$US$a2$US$a3")
            ;;
        esac
    done < <(printf '%s\n' "$flat" | awk -F'\t' -v US="$US" '
        $1 ~ /^listener:[^\/]+$/ {
            n = $1; sub(/^listener:/, "", n)
            if (!(n in ls)) { ls[n] = 1; lo[++lc] = n }
            if ($2 == "address"  && !(n in la)) la[n] = $3
            if ($2 == "secure"   && !(n in lsec)) lsec[n] = $3
            if ($2 == "certFile" && !(n in lcrt)) lcrt[n] = $3
            if ($2 == "keyFile"  && !(n in lkey)) lkey[n] = $3
            if ($2 == "map") { v = $3; sp = index(v, " ")
                if (sp) mp[++mc] = n US substr(v, 1, sp - 1) US substr(v, sp + 1) }
        }
        $1 ~ /^virtualhost:[^\/]+$/ {
            n = $1; sub(/^virtualhost:/, "", n)
            if (!(n in vs)) { vs[n] = 1; vo[++vc] = n }
            if ($2 == "vhRoot" && !(n in vr)) vr[n] = $3
            if ($2 == "configFile" && !(n in vf)) vf[n] = $3
        }
        END {
            for (i = 1; i <= lc; i++) { n = lo[i]
                printf "L%s%s%s%s%s%s%s%s%s%s\n", US, n, US, la[n], US, lsec[n], US, lcrt[n], US, lkey[n] }
            for (i = 1; i <= mc; i++) printf "M%s%s\n", US, mp[i]
            for (i = 1; i <= vc; i++) { n = vo[i]
                printf "V%s%s%s%s%s%s\n", US, n, US, vr[n], US, vf[n] }
        }')

    # server-level extprocessors (stock `extprocessor lsphp` etc.)
    check_extprocs "$flat" "server" warn "" "" ""
done

# 4. Per-vhost: vhconf, docRoot, includes, extprocessors, vhssl.
for rec in ${VHOST_LIST[@]+"${VHOST_LIST[@]}"}; do
    IFS="$US" read -r vname vroot vconf <<< "$rec"
    [ -n "$vroot" ] || vroot="\$SERVER_ROOT/$vname/"
    expand "$vroot" "" "$vname" ""; vr="$_X"
    if [ ! -d "$vr" ]; then
        add fail vhost.root "$vname" "vhRoot $vr does not exist"
        continue
    fi
    [ -n "$vconf" ] || vconf="\$VH_ROOT/conf/vhconf.conf"
    expand "$vconf" "$vr" "$vname" ""; vc="$_X"
    if [ ! -r "$vc" ]; then
        add fail vhost.conf "$vname" "configFile $vc missing or unreadable"
        continue
    fi
    vflat="$(flatten "$vc")"

    dr=""; vc_cert=""; vc_key=""; incs=()
    while IFS="$US" read -r typ val; do
        case "$typ" in
            D) dr="$val" ;;
            C) vc_cert="$val" ;;
            K) vc_key="$val" ;;
            I) incs+=("$val") ;;
        esac
    done < <(printf '%s\n' "$vflat" | awk -F'\t' -v US="$US" '
        $1 == "" && $2 == "docRoot" && !d { d = 1; print "D" US $3 }
        $1 == "vhssl" && $2 == "certFile" && !c { c = 1; print "C" US $3 }
        $1 == "vhssl" && $2 == "keyFile" && !k { k = 1; print "K" US $3 }
        $2 == "include" { print "I" US $3 }')

    if [ -z "$dr" ]; then
        add fail vhost.docroot "$vname" "no docRoot in $vc"
        dr_abs=""
    else
        expand "$dr" "$vr" "$vname" ""; dr_abs="$_X"
        if [ -d "$dr_abs" ]; then add ok vhost.docroot "$vname" "$dr_abs"
        else add fail vhost.docroot "$vname" "docRoot $dr_abs does not exist"; fi
    fi

    # every include (rules file, IP-block file) must resolve and exist.
    # OLS resolves includes like plainconf::getIncludeFile(): $VH_ROOT /
    # $DOC_ROOT are NOT expanded there, so such an include is dropped.
    for incf in ${incs[@]+"${incs[@]}"}; do
        [ -n "$incf" ] || continue
        if ! resolve_include "${vc%/*}" "$incf"; then
            add fail vhost.include "$vname" "include '$incf' cannot be resolved by OLS (only absolute, relative or \$SERVER_ROOT/ paths)"
        elif [ -r "$_P" ]; then
            add ok vhost.include "$vname" "$_P"
        else
            add fail vhost.include "$vname" "include $_P missing"
        fi
    done

    # external processors (lsphp): socket dir, binary, extUser
    check_extprocs "$vflat" "$vname" fail "$vr" "$vname" "$dr_abs"

    # per-vhost certificate
    if [ -n "$vc_cert" ] || [ -n "$vc_key" ]; then
        cpath=""; kpath=""
        [ -z "$vc_cert" ] || { expand "$vc_cert" "$vr" "$vname" "$dr_abs"; cpath="$_X"; }
        [ -z "$vc_key" ] || { expand "$vc_key" "$vr" "$vname" "$dr_abs"; kpath="$_X"; }
        check_cert "vhost $vname" "$cpath" "$kpath"
    fi
done
[ "${#VHOST_LIST[@]}" -gt 0 ] || add warn vhost.count "$INC" "no virtualhost blocks found"

# 5. Declared ports held by something other than OLS (read-only `ss`).
#    One `ss` call, no -H (iproute2 < 4.14, e.g. EL7, lacks it): the header
#    line is skipped in awk instead.
if [ "${#PORTS[@]}" -eq 0 ]; then
    :
elif ! command -v ss >/dev/null 2>&1; then
    add skip port.bound "" "ss not available"
else
    ss_out="$(ss -ltnp 2>/dev/null)"; ss_rc=$?
    if [ "$ss_rc" -ne 0 ] || [ -z "$ss_out" ]; then
        add skip port.bound "" "ss -ltnp failed (exit $ss_rc); port state not checked"
    else
        declare -A LISTENING=()
        declare -A HOLDERS=()
        while IFS="$US" read -r lp lname; do
            [ -n "$lp" ] || continue
            LISTENING["$lp"]=1
            [ "$lname" = "-" ] && continue
            case " ${HOLDERS[$lp]:-} " in *" $lname "*) ;;
                *) HOLDERS["$lp"]="${HOLDERS[$lp]:+${HOLDERS[$lp]} }$lname" ;; esac
        done < <(printf '%s\n' "$ss_out" | awk -v US="$US" '
            NR == 1 && $1 == "State" { next }
            {
                la = $4; n = split(la, parts, ":"); port = parts[n]
                if (port !~ /^[0-9]+$/) next
                found = 0; s = $0
                while (match(s, /\(\("[^"]*"/) || match(s, /\),\("[^"]*"/)) {
                    nm = substr(s, RSTART, RLENGTH); sub(/^[^"]*"/, "", nm); sub(/"$/, "", nm)
                    print port US nm; found = 1
                    s = substr(s, RSTART + RLENGTH)
                }
                if (!found) print port US "-"
            }')
        for port in "${!PORTS[@]}"; do
            if [ -z "${LISTENING[$port]:-}" ]; then
                add warn port.bound ":$port" "not listening: CPNS must restart (not reload) to bind it"
                continue
            fi
            holders="${HOLDERS[$port]:-}"
            if [ -z "$holders" ]; then
                add skip port.bound ":$port" "listening, owner unknown (ss -p needs root)"
            elif printf '%s' "$holders" | grep -Eqv '^(lshttpd|openlitespeed|litespeed)( (lshttpd|openlitespeed|litespeed))*$'; then
                add fail port.foreign ":$port" "held by: $holders"
            else
                add ok port.bound ":$port" "held by $holders"
            fi
        done
    fi
fi

finish
