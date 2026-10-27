#!/bin/bash
#############################################################################
#    OLS PRO - remove the cPanel/WHM hook. Idempotent.                      #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
# Unregisters the hooks, removes the script and the --check cron. Generated
# OLS config (/usr/local/lsws/conf/olspro-apache -> olspro-apache.d/...) and
# /etc/olspro are left in place; pass --purge to remove
# /etc/olspro/cpanel-hook.conf and hook state too.

set -u
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST=/usr/local/olspro/cpanel/olspro-hook
MANAGE_HOOKS=/usr/local/cpanel/bin/manage_hooks

if [ "$(id -u)" -ne 0 ]; then
    echo "uninstall.sh: must run as root" >&2
    exit 1
fi

rm -f /etc/cron.d/olspro-hook

if [ -x "$MANAGE_HOOKS" ]; then
    # manage_hooks needs the script's --describe to know what to delete. If
    # the installed copy is already gone, describe via our source copy at the
    # same path so the registrations do not stay behind pointing at nothing.
    restored=0
    if [ ! -x "$DEST" ] && [ -r "$SRC_DIR/hooks/olspro-hook" ]; then
        mkdir -p "$(dirname "$DEST")"
        install -m 0755 "$SRC_DIR/hooks/olspro-hook" "$DEST" && restored=1
    fi
    "$MANAGE_HOOKS" delete script "$DEST" >/dev/null 2>&1 \
        && echo "hooks unregistered" || echo "no hooks registered for $DEST"
    [ $restored -eq 1 ] && echo "(used $SRC_DIR/hooks/olspro-hook to describe the missing installed script)"
    left=$("$MANAGE_HOOKS" list 2>/dev/null | grep -c "$DEST")
    if [ "${left:-0}" -gt 0 ]; then
        echo "uninstall.sh: WARNING: $left hook registration(s) still reference $DEST:" >&2
        "$MANAGE_HOOKS" list 2>/dev/null | grep -B4 -A1 "$DEST" | sed 's/^/  /' >&2
        echo "  remove them with: $MANAGE_HOOKS delete script $DEST --manual --category <C> --event <E> --stage post" >&2
    fi
fi
rm -f "$DEST"
rmdir /usr/local/olspro/cpanel /usr/local/olspro 2>/dev/null

if [ "${1:-}" = "--purge" ]; then
    rm -f /etc/olspro/cpanel-hook.conf
    rmdir /etc/olspro 2>/dev/null
    rm -rf /var/lib/olspro /var/run/olspro
    echo "purged settings and state"
fi
echo "Done."
