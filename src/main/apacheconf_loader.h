/*****************************************************************************
*    OLS PRO - native Apache httpd.conf loader, startup integration.         *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
*****************************************************************************/
#ifndef APACHECONF_LOADER_H
#define APACHECONF_LOADER_H

/*
 * Startup hook that turns a cPanel/EA4 Apache httpd.conf into native OLS
 * configuration right before plainconf parses httpd_config.conf
 * (ROADMAP M1 / G1). Called from HttpConfigLoader::loadConfigFile().
 *
 * Enabled ONLY by environment variables; with them unset this is a no-op and
 * OLS behaves exactly like upstream:
 *
 *   OLSPRO_APACHE_CONF=/etc/apache2/conf/httpd.conf   (required to enable)
 *   OLSPRO_APACHE_ROOT=/etc/apache2                   (optional, Apache
 *                                                      ServerRoot used to
 *                                                      resolve relative
 *                                                      Include paths;
 *                                                      default: ServerRoot
 *                                                      directive, else the
 *                                                      parent of conf/)
 *   OLSPRO_APACHE_FORCE=1                             (optional, replace the
 *                                                      fragment despite
 *                                                      Include errors or a
 *                                                      large vhost drop)
 *
 * Output, under <serverRoot>/apache-generated/ (NOT conf/: conf/ is owned
 * by lsadm and chown -R'd to it, and root must never write into a tree a
 * less privileged user controls). The directory must be root-owned and not
 * group/world writable, otherwise nothing is written:
 *
 *   olspro_apache.conf                    listeners + virtualhost blocks
 *   gen-<time>-<pid>/vhosts/<id>/vhconf.conf   one per Apache <VirtualHost>
 *   olspro_apache.log                     every message of the last run
 *                                         (runs before error.log is open)
 *
 * Each run writes a fresh gen-* directory (O_EXCL|O_NOFOLLOW, one syncfs),
 * then atomically replaces the fragment, then prunes older generations; a
 * failure part way leaves the previous fragment and its generation intact.
 * The fragment carries a content hash: when the Apache config renders to
 * the same output, nothing is written at all (cheap graceful restarts).
 *
 * To activate the generated config, add this line once to
 * <serverRoot>/conf/httpd_config.conf (plainconf resolves $SERVER_ROOT):
 *
 *   include $SERVER_ROOT/apache-generated/olspro_apache.conf
 *
 * Failure policy: nothing here may prevent startup. If the Apache config
 * cannot be read, has Include/read errors, yields zero vhosts, would drop
 * more than 20% of the previous vhosts, or a file cannot be written, an
 * error is logged and the previously generated files are left as they are.
 * Every apacheconf warning (unsupported directive, bad Include, ...) is
 * logged individually with its file:line so parity gaps stay visible.
 *
 * Not done yet (follow-ups): reload on SIGHUP/inotify, replaying the log
 * into error.log once it is open.
 */

namespace apacheconf
{

enum StartupResult
{
    STARTUP_DISABLED = 0,   // OLSPRO_APACHE_CONF unset: upstream behaviour
    STARTUP_GENERATED = 1,  // generated files refreshed
    STARTUP_FAILED = -1,    // error logged, previous generated files kept
};

/* pServerRoot: OLS server root (MainServerConfig::getServerRoot()).
 * dryRun: config test mode (openlitespeed -t): parse, render and report,
 * but never write. Never throws. */
int generateFromEnv(const char *pServerRoot, bool dryRun = false);

}  // namespace apacheconf

#endif  // APACHECONF_LOADER_H
