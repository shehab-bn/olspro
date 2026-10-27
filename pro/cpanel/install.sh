#!/bin/bash
#############################################################################
#    OLS PRO - install the cPanel/WHM hook (ROADMAP G7). Idempotent.        #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
# Usage: pro/cpanel/install.sh [--no-initial-sync]
# Copies hooks/olspro-hook to /usr/local/olspro/cpanel/ and registers it with
# manage_hooks (which reads the event list from `olspro-hook --describe`).
# Re-running replaces the script and re-registers without duplicates.
# Also installs /etc/cron.d/olspro-hook: a 5-minute `--check` backstop that
# re-syncs when httpd.conf changed without any hook firing.

set -u
SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
DEST_DIR=/usr/local/olspro/cpanel
DEST="$DEST_DIR/olspro-hook"
MANAGE_HOOKS=/usr/local/cpanel/bin/manage_hooks
CONF=/etc/olspro/cpanel-hook.conf
CRON=/etc/cron.d/olspro-hook

if [ "$(id -u)" -ne 0 ]; then
    echo "install.sh: must run as root" >&2
    exit 1
fi
if [ ! -x "$MANAGE_HOOKS" ]; then
    echo "install.sh: $MANAGE_HOOKS not found -- is this a cPanel server?" >&2
    exit 1
fi
if ! bash -n "$SRC_DIR/hooks/olspro-hook"; then
    echo "install.sh: hooks/olspro-hook has a syntax error, aborting" >&2
    exit 1
fi

# Unregister the PREVIOUS version first, while $DEST still holds it:
# manage_hooks builds the delete list from the script's own --describe, so
# deleting after the copy would only remove the new version's entries and
# leave renamed/changed older registrations behind.
if [ -x "$DEST" ]; then
    "$MANAGE_HOOKS" delete script "$DEST" >/dev/null 2>&1
fi

mkdir -p "$DEST_DIR" /etc/olspro
install -m 0755 -o root -g root "$SRC_DIR/hooks/olspro-hook" "$DEST.new"
mv -f "$DEST.new" "$DEST"

# Anything still registered for $DEST was not described by the old script
# (or an even older one); drop what the new describe knows, then report.
"$MANAGE_HOOKS" delete script "$DEST" >/dev/null 2>&1
left=$("$MANAGE_HOOKS" list 2>/dev/null | grep -c "$DEST")
if [ "${left:-0}" -gt 0 ]; then
    echo "install.sh: WARNING: $left stale hook registration(s) still reference $DEST:" >&2
    "$MANAGE_HOOKS" list 2>/dev/null | grep -B4 -A1 "$DEST" | sed 's/^/  /' >&2
    echo "  remove them with: $MANAGE_HOOKS delete script $DEST --manual --category <C> --event <E> --stage post" >&2
fi

if [ ! -f "$CONF" ]; then
    cat > "$CONF" <<'EOF'
# OLS PRO cPanel hook settings (sourced by olspro-hook). Defaults shown.
#ENABLED=1                                  # 0 = hook does nothing
#NATIVE=0                                   # 1 = OLS loads httpd.conf itself; reload only
#ACTIVE_WEBSERVER=auto                      # ols | apache | auto: start OLS when it is down
#                                           # only if designated (auto = it was seen serving)
#                                           # and nothing else listens on :80
#APACHE2OLS=/usr/local/lsws/bin/apache2ols
#OUT=/usr/local/lsws/conf/olspro-apache     # symlink to the live generation; include
#                                           # $OUT/olspro_apache.conf from httpd_config.conf
#DEBOUNCE=8
#MIN_KEEP_PCT=50                            # vs. httpd.conf vhosts and /etc/trueuserdomains
#MIN_FREE_MB=64
#VALIDATE_STRICT=0                          # 1 = per-vhost [ERROR]s from -t also fail
#STATE_DIR=/var/lib/olspro
EOF
    chmod 0644 "$CONF"
fi

if ! "$MANAGE_HOOKS" add script "$DEST"; then
    echo "install.sh: manage_hooks add failed" >&2
    exit 1
fi

echo "Registered hooks:"
"$MANAGE_HOOKS" list 2>/dev/null | grep -B4 -A2 "$DEST" | grep -E 'event|stage|hook|escalate' | sed 's/^/  /'

cat > "$CRON.new" <<EOF
# OLS PRO: re-sync OLS when httpd.conf changed without a cPanel hook firing
*/5 * * * * root $DEST --check >/dev/null 2>&1
EOF
chmod 0644 "$CRON.new" && mv -f "$CRON.new" "$CRON"

if [ "${1:-}" != "--no-initial-sync" ]; then
    echo "Initial sync (foreground)..."
    "$DEST" --now || echo "initial sync reported a problem, see /usr/local/lsws/logs/olspro-hook.log"
fi
echo "Done. Log: /usr/local/lsws/logs/olspro-hook.log   Uninstall: $SRC_DIR/uninstall.sh"
