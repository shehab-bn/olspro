#!/usr/bin/env bash
#############################################################################
#    OLS PRO - licence-shim guard (ROADMAP G10).                            #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
#
# Why this exists: on artcp a vendor "esp litespeed cron" dropped
# /usr/local/ecp/lsws/socket.so as an LD_PRELOAD shim and replaced
# bin/lshttpd; every OLS worker segfaulted in a crash loop.
#
# Usage: olspro-shimguard {check|fix [--all-preload]|watch|record [good-binary]|unlock|undo <backup-dir>}
#   check   read-only scan. exit 0 = clean, 1 = findings, 2 = error
#   record  store sha256 manifest + golden copy of bin/openlitespeed (or of
#           the given known-good binary). Run after every olspro install/upgrade.
#   fix     scan, then revert every finding. Refuses (exit 2) unless this host
#           is a recorded OLS PRO install (manifest + matching golden copy).
#           Every step is logged to <state>/backup/<stamp>/actions.log with the
#           original files saved next to it, so 'undo <that dir>' puts them back.
#           --all-preload also strips /etc/ld.so.preload entries that are not
#           known shims (by default those are only reported).
#   watch   check; on findings log to syslog and run fix (alert only when the
#           host is not a recorded OLS PRO install, or SHIMGUARD_WATCH_FIX=0).
#           If only running processes still carry the shim, restarts lsws.
#           Driven by olspro-shimguard.timer.
#   unlock  chattr -i the binary (do this before upgrading, then 'record').
#   undo D  reverse every step of the fix run whose backup dir is D.
#
# A changed bin/openlitespeed that is still an OpenLiteSpeed build (version
# banner "LiteSpeed/<ver> Open") is treated as an upgrade: reported, never
# rolled back. Only a non-OLS binary (e.g. an LSWS swap) is restored.
#
# Environment (optional):
#   SHIMGUARD_ROOT           prefix for every system path (fake tree for tests)
#   LSWS_ROOT                server root (default $SHIMGUARD_ROOT/usr/local/lsws)
#   SHIMGUARD_STATE          state dir (default $SHIMGUARD_ROOT/var/lib/olspro-shimguard)
#   SHIMGUARD_PROC           procfs to scan (default /proc)
#   SHIMGUARD_UNITS          systemd units to protect (default "lshttpd lsws openlitespeed")
#   SHIMGUARD_CRON_RE        lowercase awk ERE for licence-tool cron lines
#   SHIMGUARD_PRELOAD_ALLOW  awk ERE of /etc/ld.so.preload entries to tolerate
#   SHIMGUARD_BUILD_RE       grep ERE identifying an OLS build (upgrade vs swap)
#   SHIMGUARD_WATCH_FIX      1 (default) = watch auto-fixes, 0 = alert only
#   SHIMGUARD_RESTART        restart lsws when a running process still carries
#                            the shim after the on-disk fix (watch default 1,
#                            fix default 0); at most once per
#   SHIMGUARD_RESTART_INTERVAL seconds (default 1800)
#   SHIMGUARD_RESTART_CMD    command used instead of systemctl/lswsctrl restart
#   SHIMGUARD_IMMUTABLE      1 = fix also chattr +i's the recorded binary
#                            (default 0: installers must run 'unlock' first)
#   SHIMGUARD_KEEP_BACKUPS   fix backup dirs to keep (default 20)
#   SHIMGUARD_SYSTEMD_VERSION  override the detected systemd version

set -u
umask 022
export LC_ALL=C
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$PATH

PROG=olspro-shimguard
R="${SHIMGUARD_ROOT:-}"
R="${R%/}"
RR=""
[ -n "$R" ] && RR="$(cd "$R" 2>/dev/null && pwd -P)"
LSWS_ROOT="${LSWS_ROOT:-$R/usr/local/lsws}"
STATE="${SHIMGUARD_STATE:-$R/var/lib/olspro-shimguard}"
PROC="${SHIMGUARD_PROC:-/proc}"
UNITS="${SHIMGUARD_UNITS:-lshttpd lsws openlitespeed}"
CRON_RE="${SHIMGUARD_CRON_RE:-(/usr/local/ecp|esp[^a-z0-9]+litespeed|litespeed[^a-z0-9]+(cron|licen[cs]e)|lsws[^ ]*licen[cs]e|lslicense|lshttpd[^ ]* +-r( |$)|socket[.]so)}"
PRELOAD_ALLOW="${SHIMGUARD_PRELOAD_ALLOW:-}"
BUILD_RE="${SHIMGUARD_BUILD_RE:-LiteSpeed/[0-9][0-9.]* Open}"
IMMUTABLE="${SHIMGUARD_IMMUTABLE:-0}"
KEEP="${SHIMGUARD_KEEP_BACKUPS:-20}"
RESTART="${SHIMGUARD_RESTART:-0}"
RESTART_MIN="${SHIMGUARD_RESTART_INTERVAL:-1800}"
SHIM_RE='socket[.]so|/usr/local/ecp/'
# ld.so.preload entries auto-stripped: known shims or anything litespeed-named.
PRELOAD_SHIM_RE="$SHIM_RE|lsws|litespeed|lshttpd"
ENV_RE='ld_(preload|audit)[ \t]*='
MARK='#olspro-shimguard-disabled# '
BIN="$LSWS_ROOT/bin/openlitespeed"
# Names lswsctrl / systemd may exec; each must resolve to $BIN.
# litespeed is what lswsctrl actually runs (litespeed -> lshttpd -> openlitespeed).
LINKS="lshttpd litespeed"
MANIFEST="$STATE/manifest"
GOLDEN="$STATE/golden/openlitespeed"
DROPIN_NAME=50-olspro-nopreload.conf
UNIT_DIRS="$R/etc/systemd/system $R/run/systemd/system $R/usr/lib/systemd/system $R/lib/systemd/system"
STRIP_ALL_PRELOAD=0

NFAIL=0
NWARN=0
NFIXW=0
NPROC=0
PROC_DIRTY=0
BIN_UPGRADED=0
QUIET="${SHIMGUARD_QUIET:-0}"
B=""

say()  { printf '%s\n' "$*"; }
ok()   { [ "$QUIET" = 1 ] || say "[ OK ] $1: $2"; }
warn() { NWARN=$((NWARN + 1)); say "[WARN] $1: $2"; }
fixw() { NFIXW=$((NFIXW + 1)); warn "$@"; }        # warning that 'fix' resolves
fail() { NFAIL=$((NFAIL + 1)); say "[FAIL] $1: $2"; }
failp() { NPROC=$((NPROC + 1)); fail "$@"; }       # running-process finding
die()  { say "$PROG: $*" >&2; exit 2; }

log()
{
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S') $*"
    say "  -> $*"
    mkdir -p "$STATE" 2>/dev/null && printf '%s\n' "$line" >> "$STATE/shimguard.log" 2>/dev/null
    if [ -z "$R" ] && command -v logger >/dev/null 2>&1; then
        logger -t "$PROG" -- "$*" 2>/dev/null
    fi
    return 0
}

sha()
{
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    else
        shasum -a 256 "$1" | awk '{print $1}'
    fi
}

manifest_get()
{
    [ -f "$MANIFEST" ] || return 0
    awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$MANIFEST"
}

is_immutable()
{
    command -v lsattr >/dev/null 2>&1 || return 1
    [ -f "$1" ] && [ ! -L "$1" ] || return 1
    lsattr -d "$1" 2>/dev/null | awk '{print $1}' | grep -q i
}

is_elf()
{
    [ -f "$1" ] || return 1
    [ "$(head -c 4 "$1" 2>/dev/null | tail -c 3)" = ELF ]
}

# An OpenLiteSpeed build carries "LiteSpeed/<ver> Open (" in its version
# banner (src/main/lshttpdmain.cpp); LSWS Enterprise does not.
is_ols_build()
{
    is_elf "$1" && grep -a -q -E -- "$BUILD_RE" "$1" 2>/dev/null
}

# Canonical path of $1 (follows symlinks). With a fake root, refuse paths
# that resolve outside it so tests never touch the real system.
resolve()
{
    local p
    p=$(readlink -f "$1" 2>/dev/null)
    [ -n "$p" ] || p="$1"
    if [ -n "$R" ]; then
        case "$p" in "$R"/*) say "$p"; return 0 ;; esac
        if [ -n "$RR" ]; then
            case "$p" in "$RR"/*) say "$p"; return 0 ;; esac
        fi
        return 1
    fi
    say "$p"
}

systemd_version()
{
    local v="${SHIMGUARD_SYSTEMD_VERSION:-}"
    if [ -z "$v" ] && [ -z "$R" ] && command -v systemctl >/dev/null 2>&1; then
        v=$(systemctl --version 2>/dev/null | awk 'NR == 1 { print $2 }')
    fi
    case "$v" in ''|*[!0-9]*) v=999 ;; esac
    say "$v"
}
SYSTEMD_V="$(systemd_version)"

DROPIN_BODY_NEW='# OLS PRO shimguard (ROADMAP G10): never hand an LD_PRELOAD/LD_AUDIT shim to lshttpd.
[Service]
UnsetEnvironment=LD_PRELOAD LD_AUDIT'
# systemd < 235 ignores UnsetEnvironment=; blank the variables instead.
DROPIN_BODY_OLD='# OLS PRO shimguard (ROADMAP G10): systemd < 235 has no UnsetEnvironment=, so blank
# LD_PRELOAD/LD_AUDIT (weaker: EnvironmentFile= overrides it; shimguard scans those).
[Service]
Environment=LD_PRELOAD= LD_AUDIT='
if [ "$SYSTEMD_V" -lt 235 ]; then DROPIN_BODY="$DROPIN_BODY_OLD"; else DROPIN_BODY="$DROPIN_BODY_NEW"; fi

# Our own drop-in, in either form, is not an LD_PRELOAD source.
is_our_dropin()
{
    local c
    [ "${1##*/}" = "$DROPIN_NAME" ] || return 1
    c="$(cat "$1" 2>/dev/null)"
    [ "$c" = "$DROPIN_BODY_NEW" ] || [ "$c" = "$DROPIN_BODY_OLD" ]
}

# Active (non-comment) lines of $1 matching lowercase ERE $2, as "N: text".
match_lines()
{
    awk -v re="$2" '!/^[ \t]*#/ && tolower($0) ~ re { printf "%d: %s\n", NR, $0 }' "$1" 2>/dev/null
}

list_files()
{
    local f
    for f in "$@"; do
        [ -f "$f" ] && [ ! -L "$f" ] && say "$f"
    done
    return 0
}

cron_tables()
{
    list_files "$R/etc/crontab" "$R"/etc/cron.d/* "$R"/var/spool/cron/* \
               "$R"/var/spool/cron/crontabs/*
}

cron_scripts()
{
    list_files "$R"/etc/cron.hourly/* "$R"/etc/cron.daily/* \
               "$R"/etc/cron.weekly/* "$R"/etc/cron.monthly/*
}

unit_exists()
{
    local d
    for d in $UNIT_DIRS; do
        [ -f "$d/$1.service" ] && return 0
    done
    return 1
}

# Unit files, drop-ins and environment files that can feed lshttpd's env,
# plus lswsctrl and the lsws_env it sources. Paths are resolved (unit names
# are often symlinks/aliases of lshttpd.service) and de-duplicated.
env_sources()
{
    local u d f ef
    {
        for u in $UNITS; do
            for d in $UNIT_DIRS; do
                for f in "$d/$u.service" "$d/$u.service.d"/*.conf; do
                    [ -f "$f" ] || continue
                    is_our_dropin "$f" && continue
                    say "$f"
                    # EnvironmentFile=[-]/path
                    awk '/^[ \t]*EnvironmentFile[ \t]*=/ { sub(/^[ \t]*EnvironmentFile[ \t]*=[ \t]*-?/, ""); print }' "$f" |
                    while read -r ef; do
                        [ -f "$R$ef" ] && say "$R$ef"
                    done
                done
            done
        done
        for f in "$R/etc/environment" "$R/etc/sysconfig/lsws" "$R/etc/sysconfig/lshttpd" \
                 "$R/etc/sysconfig/openlitespeed" "$R/etc/default/lsws" \
                 "$R/etc/default/lshttpd" "$R/etc/default/openlitespeed" \
                 "$LSWS_ROOT/bin/lswsctrl" "$LSWS_ROOT/bin/lsws_env"; do
            [ -f "$f" ] && say "$f"
        done
    } | while read -r f; do resolve "$f"; done | sort -u
}

preload_file() { say "$R/etc/ld.so.preload"; }

# glibc splits ld.so.preload on whitespace/colon and has NO comment syntax,
# so every token is a live preload. Allowlisted entries are never listed.
preload_tokens()
{
    local f
    f="$(preload_file)"
    [ -f "$f" ] || return 0
    tr ' \t:' '\n\n\n' < "$f" | awk -v allow="$PRELOAD_ALLOW" \
        'NF && !(allow != "" && $0 ~ allow) { print }'
}

# Entries we strip automatically: known shims / litespeed-named libraries.
preload_bad()
{
    preload_tokens | awk -v re="$PRELOAD_SHIM_RE" 'tolower($0) ~ re { print }'
}

# Anything else (EDR agents, snoopy, ...): reported, left alone by default.
preload_other()
{
    preload_tokens | awk -v re="$PRELOAD_SHIM_RE" '!(tolower($0) ~ re) { print }'
}

shim_payloads()
{
    local d
    for d in "$R/usr/local/ecp" "$LSWS_ROOT/bin" "$LSWS_ROOT/lib"; do
        [ -d "$d" ] || continue
        find "$d" -maxdepth 4 \( -name 'socket.so' -o -path "$R/usr/local/ecp/*.so" \) \
            \( -type f -o -type l \) 2>/dev/null
    done
}

link_target()
{
    case "$1" in
        lshttpd) say openlitespeed ;;
        litespeed) say lshttpd ;;
        *) say openlitespeed ;;
    esac
}

# bin/$1 must resolve to $BIN (symlink chain) or be byte-identical to it
# ($BIN itself is verified against the manifest separately).
link_ok()
{
    local l="$LSWS_ROOT/bin/$1"
    if [ -L "$l" ]; then
        [ -e "$BIN" ] && [ "$(readlink -f "$l" 2>/dev/null)" = "$(readlink -f "$BIN" 2>/dev/null)" ]
        return
    fi
    [ -f "$l" ] && [ -f "$BIN" ] && cmp -s "$l" "$BIN"
}

# Host is a recorded OLS PRO install: manifest + golden copy that matches it.
recorded_install()
{
    local want
    want=$(manifest_get sha256)
    if [ -z "$want" ]; then
        say "$PROG: no manifest at $MANIFEST - not a recorded OLS PRO install; refusing to change anything (run '$PROG record' after installing OLS PRO)"
        return 1
    fi
    if [ ! -f "$GOLDEN" ] || [ "$(sha "$GOLDEN")" != "$want" ]; then
        say "$PROG: golden copy $GOLDEN missing or does not match $MANIFEST; refusing to change anything (re-run '$PROG record')"
        return 1
    fi
    return 0
}

############################################################################
# checks
############################################################################

check_preload()
{
    local f e n=0
    f="$(preload_file)"
    if [ ! -f "$f" ]; then
        ok preload "no $f"
        return
    fi
    for e in $(preload_bad); do
        n=$((n + 1))
        fail preload "$f preloads KNOWN SHIM $e into every process"
    done
    for e in $(preload_other); do
        n=$((n + 1))
        if [ "$STRIP_ALL_PRELOAD" = 1 ]; then
            fixw preload "$f preloads $e into every process; 'fix --all-preload' strips it"
        else
            warn preload "$f preloads $e into every process (not a known shim, left alone; allow with SHIMGUARD_PRELOAD_ALLOW or strip with '$PROG fix --all-preload')"
        fi
    done
    [ "$n" -eq 0 ] && ok preload "$f has no active entries"
}

check_env()
{
    local f hits n=0
    for f in $(env_sources); do
        hits=$(match_lines "$f" "$ENV_RE")
        [ -n "$hits" ] || continue
        n=$((n + 1))
        fail env "$f sets LD_PRELOAD/LD_AUDIT: $(say "$hits" | head -2 | tr '\n' ' ')"
    done
    [ "$n" -eq 0 ] && ok env "no LD_PRELOAD in lsws units/environment files/lswsctrl/lsws_env"
    n=0
    for f in $UNITS; do
        unit_exists "$f" || continue
        n=$((n + 1))
        if [ ! -f "$R/etc/systemd/system/$f.service.d/$DROPIN_NAME" ]; then
            fixw env "$f.service lacks $DROPIN_NAME (unsets LD_PRELOAD); 'fix' installs it"
        elif [ "$(cat "$R/etc/systemd/system/$f.service.d/$DROPIN_NAME")" != "$DROPIN_BODY" ]; then
            fixw env "$f.service $DROPIN_NAME is modified/outdated for systemd $SYSTEMD_V; 'fix' rewrites it"
        else
            ok env "$f.service has $DROPIN_NAME"
        fi
    done
    if [ "$n" -gt 0 ] && [ "$SYSTEMD_V" -lt 235 ]; then
        warn env "systemd $SYSTEMD_V < 235 ignores UnsetEnvironment=; the drop-in only blanks LD_PRELOAD (an EnvironmentFile= can override it) - rely on the file scans above"
    fi
}

check_procs()
{
    local d pid comm env hits n=0
    [ -d "$PROC" ] || { ok proc "no $PROC"; return; }
    for d in "$PROC"/[0-9]*; do
        [ -r "$d/comm" ] || continue
        comm=$(cat "$d/comm" 2>/dev/null) || continue
        case "$comm" in
            lshttpd*|openlitespeed*|litespeed*|lscgid*) ;;
            *) continue ;;
        esac
        pid=${d##*/}
        n=$((n + 1))
        env=$(tr '\0' '\n' < "$d/environ" 2>/dev/null | grep -E '^LD_(PRELOAD|AUDIT)=.' | head -1)
        if [ -n "$env" ]; then
            PROC_DIRTY=1
            failp proc "pid $pid ($comm) running with $env"
        fi
        hits=$(awk -v re="$SHIM_RE" 'NF >= 6 && tolower($6) ~ re { print $6 }' "$d/maps" 2>/dev/null |
               sort -u | head -3 | tr '\n' ' ')
        if [ -n "$hits" ]; then
            PROC_DIRTY=1
            failp proc "pid $pid ($comm) has shim mapped: $hits"
        fi
    done
    [ "$PROC_DIRTY" -eq 0 ] && ok proc "$n lshttpd/openlitespeed process(es), none carry a shim"
}

check_link()
{
    local name="$1" l="$LSWS_ROOT/bin/$1"
    if link_ok "$name"; then
        ok bin "$l -> openlitespeed"
    elif [ -L "$l" ]; then
        fail bin "$l is a symlink to $(readlink "$l") which does not resolve to openlitespeed"
    elif [ -e "$l" ]; then
        fail bin "$l is a regular file that differs from the OLS PRO binary (replaced $name)"
    else
        fail bin "$l missing (lswsctrl runs bin/litespeed -> lshttpd -> openlitespeed)"
    fi
}

check_binary()
{
    local want have p l
    want=$(manifest_get sha256)
    if [ ! -f "$BIN" ]; then
        fail bin "$BIN missing"
    elif [ -z "$want" ]; then
        warn bin "no manifest at $MANIFEST (run: $PROG record); fix/watch change nothing until then"
    else
        have=$(sha "$BIN")
        if [ "$have" = "$want" ]; then
            ok bin "$BIN matches manifest sha256 ${want:0:16}..."
        elif is_ols_build "$BIN"; then
            BIN_UPGRADED=1
            warn bin "$BIN sha256 ${have:0:16}... != manifest ${want:0:16}... but it is an OpenLiteSpeed build (upgrade?); NOT restored - run '$PROG record' to accept it"
        else
            fail bin "$BIN sha256 ${have:0:16}... != manifest ${want:0:16}... and is not an OpenLiteSpeed build (replaced binary)"
        fi
        if [ ! -f "$GOLDEN" ]; then
            warn bin "golden copy $GOLDEN missing; fix cannot restore the binary"
        fi
    fi
    for l in $LINKS; do
        check_link "$l"
    done
    if [ "$IMMUTABLE" = 1 ] && [ -f "$BIN" ] && [ -n "$want" ] && command -v lsattr >/dev/null 2>&1; then
        if is_immutable "$BIN"; then
            ok bin "$BIN is immutable"
        elif [ "$(sha "$BIN")" = "$want" ]; then
            fixw bin "$BIN not immutable; 'fix' runs chattr +i (SHIMGUARD_IMMUTABLE=1)"
        fi
    fi
    for p in $(shim_payloads); do
        fail shim "shim payload present: $p"
    done
}

check_cron()
{
    local f hits n=0
    for f in $(cron_tables); do
        hits=$(match_lines "$f" "$CRON_RE")
        [ -n "$hits" ] || continue
        n=$((n + 1))
        fail cron "$f runs licence tooling: $(say "$hits" | head -2 | tr '\n' ' ')"
    done
    for f in $(cron_scripts); do
        [ -x "$f" ] || continue
        hits=$(match_lines "$f" "$CRON_RE")
        [ -n "$hits" ] || continue
        n=$((n + 1))
        fail cron "$f (run-parts script) runs licence tooling: $(say "$hits" | head -1)"
    done
    [ "$n" -eq 0 ] && ok cron "no litespeed licence-tool cron entries"
}

run_checks()
{
    NFAIL=0
    NWARN=0
    NFIXW=0
    NPROC=0
    PROC_DIRTY=0
    BIN_UPGRADED=0
    say "== $PROG: LSWS_ROOT=$LSWS_ROOT${R:+ (root prefix $R)}"
    check_cron
    check_preload
    check_env
    check_procs
    check_binary
    say "== $NFAIL finding(s), $NWARN warning(s)"
}

############################################################################
# fix (every step reversible via actions.log)
############################################################################

# The backup dir is created lazily on the first change, so a run that only
# finds running-process issues (or nothing fixable) leaves no empty dirs.
need_b()
{
    [ -n "$B" ] && return 0
    B="$STATE/backup/$(date +%Y%m%d-%H%M%S)-$$"
    mkdir -p "$B/files" "$B/quarantine" || die "cannot create $B"
    chmod 700 "$STATE/backup" "$B" 2>/dev/null
    : > "$B/actions.log"
    log "fix: backup dir $B"
}

act() { need_b; printf '%s\t%s\t%s\n' "$1" "$2" "${3:-}" >> "$B/actions.log"; }

prune_backups()
{
    local d n=0
    case "$KEEP" in ''|*[!0-9]*) return 0 ;; esac
    [ "$KEEP" -gt 0 ] && [ -d "$STATE/backup" ] || return 0
    for d in $(ls -1 "$STATE/backup" 2>/dev/null | sort -r); do
        case "$d" in [0-9]*-[0-9]*-[0-9]*) ;; *) continue ;; esac
        n=$((n + 1))
        [ "$n" -le "$KEEP" ] && continue
        rm -rf "${STATE:?}/backup/$d" && log "pruned old backup $STATE/backup/$d (keep $KEEP)"
    done
}

# Saves $1 as-is (a symlink stays a symlink). Callers that edit content
# pass the resolved path, so the edited file itself is what gets saved.
backup_file()
{
    local p="$1"
    need_b
    [ -e "$B/files$p" ] || [ -L "$B/files$p" ] && return 0
    mkdir -p "$B/files$(dirname "$p")" || return 1
    cp -a "$p" "$B/files$p" || return 1
    act backup "$p"
}

# Drop the immutable bit (vendor tools set it too); undo puts it back.
unlock_for_write()
{
    if is_immutable "$1"; then
        chattr -i "$1" && act unchattr "$1" && log "chattr -i $1"
    fi
}

# Rewrite $1 commenting out active lines matching $2. Works on the resolved
# file so a symlinked unit is backed up and edited consistently.
comment_out()
{
    local f re="$2" tmp
    f=$(resolve "$1") || { warn fix "$1 resolves outside the root, skipped"; return 1; }
    need_b
    tmp="$B/.tmp.$$"
    unlock_for_write "$f"
    backup_file "$f" || { warn fix "cannot back up $f, skipped"; return 1; }
    awk -v re="$re" -v m="$MARK" \
        '!/^[ \t]*#/ && tolower($0) ~ re { print m $0; next } { print }' "$f" > "$tmp" &&
        cat "$tmp" > "$f" || { rm -f "$tmp"; warn fix "cannot rewrite $f"; return 1; }
    rm -f "$tmp"
    log "commented out matching lines in $f"
}

fix_cron()
{
    local f
    for f in $(cron_tables); do
        [ -n "$(match_lines "$f" "$CRON_RE")" ] || continue
        comment_out "$f" "$CRON_RE" || continue
        # Debian cron only rereads the spool when the directory mtime moves.
        case "$f" in */var/spool/cron/*) touch "$(dirname "$f")" 2>/dev/null ;; esac
    done
    for f in $(cron_scripts); do
        [ -x "$f" ] && [ -n "$(match_lines "$f" "$CRON_RE")" ] || continue
        unlock_for_write "$f"
        backup_file "$f" || continue
        chmod a-x "$f" && log "chmod a-x $f (run-parts will skip it)"
    done
}

fix_preload()
{
    local f tmp drop
    drop="$(preload_bad)"
    [ "$STRIP_ALL_PRELOAD" = 1 ] && drop="$drop
$(preload_other)"
    [ -n "$(say "$drop" | tr -d ' \n')" ] || return 0
    f=$(resolve "$(preload_file)") || { warn fix "$(preload_file) resolves outside the root"; return; }
    [ -f "$f" ] || return 0
    need_b
    tmp="$B/.tmp.$$"
    unlock_for_write "$f"
    backup_file "$f" || { warn fix "cannot back up $f"; return; }
    # No comment syntax in ld.so.preload: drop the flagged tokens, keep the rest.
    tr ' \t:' '\n\n\n' < "$f" | awk -v drop="$drop" \
        'BEGIN { n = split(drop, a, "\n"); for (i = 1; i <= n; i++) if (a[i] != "") d[a[i]] = 1 }
         NF && !($0 in d) { print }' > "$tmp"
    if [ -s "$tmp" ]; then
        cat "$tmp" > "$f" && log "removed shim entries from $f (other entries kept)"
    else
        rm -f "$f" && log "removed $f (backup kept)"
    fi
    rm -f "$tmp"
}

fix_env()
{
    local f u d changed=0
    for f in $(env_sources); do
        [ -n "$(match_lines "$f" "$ENV_RE")" ] || continue
        comment_out "$f" "$ENV_RE" && changed=1
    done
    for u in $UNITS; do
        unit_exists "$u" || continue
        d="$R/etc/systemd/system/$u.service.d"
        f="$d/$DROPIN_NAME"
        [ -f "$f" ] && [ "$(cat "$f")" = "$DROPIN_BODY" ] && continue
        mkdir -p "$d" || continue
        if [ -e "$f" ]; then backup_file "$f"; else act created "$f"; fi
        printf '%s\n' "$DROPIN_BODY" > "$f" && log "installed $f" && changed=1
    done
    if [ "$changed" = 1 ] && [ -z "$R" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload && log "systemctl daemon-reload"
    fi
}

fix_shims()
{
    local p q
    for p in $(shim_payloads); do
        need_b
        q="$B/quarantine$p"
        mkdir -p "$(dirname "$q")" || continue
        unlock_for_write "$p"
        if mv "$p" "$q"; then
            chmod 000 "$q" 2>/dev/null
            act quarantine "$p"
            log "quarantined $p -> $q"
        else
            warn fix "cannot quarantine $p (left in place)"
        fi
    done
}

fix_link()
{
    local name="$1" l="$LSWS_ROOT/bin/$1" t
    link_ok "$name" && return 0
    [ -f "$BIN" ] || return 0
    t=$(link_target "$name")
    if [ -e "$l" ] || [ -L "$l" ]; then
        unlock_for_write "$l"
        backup_file "$l" || { warn fix "cannot back up $l"; return; }
    else
        act created "$l"
    fi
    rm -f "$l" && ln -s "$t" "$l" && log "relinked $l -> $t"
}

fix_binary()
{
    local want l
    want=$(manifest_get sha256)
    [ -n "$want" ] || return 0
    # Restore only when missing or clearly not an OLS build; a changed OLS
    # build is an upgrade and is never rolled back.
    if [ ! -f "$BIN" ] || { [ "$(sha "$BIN")" != "$want" ] && ! is_ols_build "$BIN"; }; then
        if [ -f "$GOLDEN" ] && [ "$(sha "$GOLDEN")" = "$want" ]; then
            if [ -e "$BIN" ] || [ -L "$BIN" ]; then
                unlock_for_write "$BIN"
                backup_file "$BIN" || { warn fix "cannot back up $BIN"; return; }
            else
                act created "$BIN"
            fi
            rm -f "$BIN" && cp -p "$GOLDEN" "$BIN" && chmod 0755 "$BIN" &&
                log "restored $BIN from golden copy (sha256 ${want:0:16}...)"
        else
            warn fix "golden copy missing or corrupt; $BIN NOT restored - reinstall olspro"
        fi
    fi
    # lshttpd first: litespeed resolves through it.
    for l in $LINKS; do
        fix_link "$l"
    done
    if [ "$IMMUTABLE" = 1 ] && [ -f "$BIN" ] && [ "$(sha "$BIN")" = "$want" ] && ! is_immutable "$BIN"; then
        if chattr +i "$BIN" 2>/dev/null; then
            act chattr "$BIN"
            log "chattr +i $BIN"
        else
            warn fix "chattr +i $BIN failed (no CAP_LINUX_IMMUTABLE / unsupported fs)"
        fi
    fi
}

# Running processes keep a shim until lsws is re-exec'd with a clean env.
# Returns 0 only when a restart was performed.
restart_if_dirty()
{
    local u now last ctl="$LSWS_ROOT/bin/lswsctrl"
    [ "$PROC_DIRTY" = 1 ] || return 1
    if [ "$RESTART" != 1 ]; then
        say "NOTE: running workers still carry the shim; restart lsws (systemctl restart lshttpd) or set SHIMGUARD_RESTART=1"
        return 1
    fi
    now=$(date +%s)
    last=$(cat "$STATE/last-restart" 2>/dev/null)
    case "$last" in ''|*[!0-9]*) last=0 ;; esac
    case "$RESTART_MIN" in ''|*[!0-9]*) RESTART_MIN=1800 ;; esac
    if [ $((now - last)) -lt "$RESTART_MIN" ]; then
        log "running workers still carry the shim but lsws was restarted $((now - last))s ago; not restarting again - investigate by hand"
        return 1
    fi
    printf '%s\n' "$now" > "$STATE/last-restart" 2>/dev/null
    if [ -n "${SHIMGUARD_RESTART_CMD:-}" ]; then
        env -u LD_PRELOAD -u LD_AUDIT sh -c "$SHIMGUARD_RESTART_CMD" &&
            { log "restarted lsws via SHIMGUARD_RESTART_CMD (running workers carried the shim)"; return 0; }
        log "SHIMGUARD_RESTART_CMD failed"
        return 1
    fi
    if [ -n "$R" ]; then
        say "NOTE: fake root; not restarting lsws"
        return 1
    fi
    if command -v systemctl >/dev/null 2>&1; then
        for u in $UNITS; do
            unit_exists "$u" || continue
            systemctl is-active --quiet "$u" 2>/dev/null || continue
            systemctl restart "$u" &&
                { log "systemctl restart $u (running workers carried the shim)"; return 0; }
        done
    fi
    # Not under systemd: full stop/start (a graceful restart keeps the old env).
    if [ -x "$ctl" ]; then
        env -u LD_PRELOAD -u LD_AUDIT "$ctl" stop >/dev/null 2>&1
        sleep 2
        env -u LD_PRELOAD -u LD_AUDIT "$ctl" start >/dev/null 2>&1 &&
            { log "lswsctrl stop/start (running workers carried the shim)"; return 0; }
    fi
    log "could not restart lsws; restart it by hand"
    return 1
}

do_fix()
{
    if [ -z "$R" ] && [ "$(id -u)" != 0 ]; then
        die "fix must run as root"
    fi
    recorded_install || return 2
    run_checks
    if [ "$NFAIL" -eq 0 ] && [ "$NFIXW" -eq 0 ]; then
        say "nothing to fix"
        return 0
    fi
    B=""
    if [ $((NFAIL - NPROC)) -gt 0 ] || [ "$NFIXW" -gt 0 ]; then
        fix_cron
        fix_preload
        fix_env
        fix_shims
        fix_binary
    fi
    if [ -n "$B" ]; then
        prune_backups
        say "== re-check after fix (undo with: $PROG undo $B)"
    else
        say "== re-check (no on-disk change was needed)"
    fi
    run_checks
    if [ "$PROC_DIRTY" = 1 ]; then
        if [ $((NFAIL - NPROC)) -eq 0 ]; then
            if restart_if_dirty; then
                say "== re-check after restart"
                run_checks
            fi
        else
            say "NOTE: on-disk findings remain; not restarting lsws"
        fi
    fi
    return 0
}

do_undo()
{
    local d="${1:-}" a p x
    [ -n "$d" ] && [ -f "$d/actions.log" ] || die "usage: $PROG undo <backup-dir with actions.log>"
    awk '{ l[NR] = $0 } END { for (i = NR; i > 0; i--) print l[i] }' "$d/actions.log" |
    while IFS="$(printf '\t')" read -r a p x; do
        case "$a" in
            chattr)
                chattr -i "$p" 2>/dev/null; log "undo: chattr -i $p" ;;
            unchattr)
                chattr +i "$p" 2>/dev/null; log "undo: chattr +i $p" ;;
            created)
                chattr -i "$p" 2>/dev/null; rm -f "$p"; log "undo: removed $p" ;;
            backup)
                chattr -i "$p" 2>/dev/null
                rm -f "$p"
                mkdir -p "$(dirname "$p")"
                cp -a "$d/files$p" "$p" && log "undo: restored $p" ;;
            quarantine)
                mkdir -p "$(dirname "$p")"
                chmod 0644 "$d/quarantine$p" 2>/dev/null
                mv "$d/quarantine$p" "$p" && log "undo: returned $p from quarantine" ;;
            *)
                warn undo "unknown action '$a' for $p" ;;
        esac
    done
    if [ -z "$R" ] && command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload
    fi
    # Mode/bits of quarantined files are not recorded; the shim was 0755 in the wild.
    return 0
}

do_record()
{
    local src="${1:-$BIN}" sum l
    [ -f "$src" ] || die "$src not found"
    if ! is_elf "$src"; then
        [ -n "$R" ] || die "$src is not an ELF binary"
    fi
    if ! is_ols_build "$src"; then
        warn record "$src has no OpenLiteSpeed version banner ($BUILD_RE) - verify it is the OLS PRO build"
    fi
    if [ -z "${1:-}" ]; then
        for l in $LINKS; do
            link_ok "$l" || warn record "$LSWS_ROOT/bin/$l does not resolve to $BIN; recording $BIN anyway"
        done
    fi
    mkdir -p "$STATE/golden" || die "cannot create $STATE"
    chmod 700 "$STATE" 2>/dev/null
    cp -p "$src" "$GOLDEN.tmp" && mv -f "$GOLDEN.tmp" "$GOLDEN" || die "cannot write $GOLDEN"
    sum=$(sha "$GOLDEN")
    {
        say "bin=$BIN"
        say "sha256=$sum"
        say "source=$src"
        say "recorded=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST" || die "cannot write $MANIFEST"
    rm -f "$STATE/upgrade-alerted"
    log "recorded manifest $MANIFEST sha256=$sum (from $src)"
}

do_watch()
{
    local out last="$STATE/last-check.txt" have rc
    RESTART="${SHIMGUARD_RESTART:-1}"
    QUIET=1
    run_checks > "$last" 2>&1
    QUIET=0
    out=$(cat "$last")
    say "$out"
    if [ "$BIN_UPGRADED" = 1 ]; then
        have=$(sha "$BIN")
        if [ "$(cat "$STATE/upgrade-alerted" 2>/dev/null)" != "$have" ]; then
            log "watch: $BIN changed but is an OpenLiteSpeed build (upgrade?); not restored - run '$PROG record' to accept it"
            printf '%s\n' "$have" > "$STATE/upgrade-alerted" 2>/dev/null
        fi
    fi
    if [ "$NFAIL" -eq 0 ]; then
        return 0
    fi
    log "watch: $NFAIL finding(s): $(say "$out" | grep '^\[FAIL\]' | head -5 | tr '\n' ' ')"
    if ! recorded_install > /dev/null || [ ! -f "$BIN" ]; then
        log "watch: not a recorded OLS PRO install (no manifest/golden copy, or no $BIN); alert only, nothing changed"
        return 2
    fi
    if [ "${SHIMGUARD_WATCH_FIX:-1}" = 1 ]; then
        do_fix
        rc=$?
        [ "$rc" = 2 ] && return 2
    fi
    return 1
}

take_lock()
{
    mkdir -p "$STATE" || die "cannot create $STATE"
    command -v flock >/dev/null 2>&1 || return 0
    exec 9>"$STATE/.lock"
    flock -n 9 || die "another $PROG run holds $STATE/.lock"
}

main()
{
    local cmd="${1:-check}" rc
    [ $# -gt 0 ] && shift
    case "$cmd" in
        check)
            run_checks
            [ "$NFAIL" -eq 0 ] && exit 0
            exit 1 ;;
        fix)
            [ "${1:-}" = "--all-preload" ] && STRIP_ALL_PRELOAD=1
            take_lock
            do_fix
            rc=$?
            [ "$rc" = 2 ] && exit 2
            [ "$NFAIL" -eq 0 ] && exit 0
            exit 1 ;;
        watch)
            take_lock
            do_watch
            exit $? ;;
        record)
            take_lock
            do_record "$@"
            exit 0 ;;
        unlock)
            if is_immutable "$BIN"; then chattr -i "$BIN" && log "chattr -i $BIN (unlock for upgrade; run '$PROG record' after)"; fi
            exit 0 ;;
        undo)
            take_lock
            do_undo "$@"
            exit 0 ;;
        -h|--help|help)
            sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            die "unknown command '$cmd' (check|fix|watch|record|unlock|undo)" ;;
    esac
}

main "$@"
