# cPanel service subdomains on OLS PRO (ROADMAP G2)

cPanel publishes `cpanel.`, `webmail.`, `whm.`, `cpcalendars.`, `cpcontacts.`,
`autodiscover.` and `autoconfig.` for every account domain. Under Apache,
cPanel's generated `httpd.conf` lists them as `ServerAlias` on the account's
vhost and proxies them to cpsrvd with mod_rewrite `[P]`, excluding
`/.well-known/`. Stock OLS has neither piece, so these hosts get the OLS
welcome page, and AutoSSL drops them from the certificate because DCV fails.

## Port map

| Host prefix | cpsrvd plain | cpsrvd SSL | Backend name |
|---|---|---|---|
| `cpanel.` | 2082 | 2083 | `cpsrvd_cpanel` |
| `whm.` | 2086 | 2087 | `cpsrvd_whm` |
| `webmail.` | 2095 | 2096 | `cpsrvd_webmail` |
| `cpcalendars.`, `cpcontacts.` | 2079 | 2080 | `cpsrvd_caldav` |
| `autodiscover.`, `autoconfig.` | 2082 | 2083 | `cpsrvd_autodiscover` (`/cgi-sys/autodiscover.cgi`) |

The browser's TLS session ends at OLS. By default OLS reaches cpsrvd on
loopback over the plain ports. Set `CPSRVD_TLS=1` to use the SSL ports
instead, which needs an OLS build that accepts an `https://` proxy address.

## Generator

`pro/cpanel/gen-service-proxy.sh`:

```bash
# 1. once, server level (append to httpd_config.conf or an included file)
pro/cpanel/gen-service-proxy.sh server  > /usr/local/lsws/conf/olspro_cpsrvd.conf

# 2. per account vhost: add the service hosts to vhAliases
pro/cpanel/gen-service-proxy.sh aliases example.com
#   -> www.example.com, cpanel.example.com, whm.example.com, webmail.example.com, ...

# 3. per account vhost: put these FIRST inside rewrite { rules <<<END_rules ... }
pro/cpanel/gen-service-proxy.sh rules
```

The rules short-circuit
`/.well-known/(acme-challenge|pki-validation|cpanel-dcv)/` with `[L]`, so
DCV files come from the account docroot exactly as they do under Apache. The
vhost also needs a static `/.well-known/` context. tos-litespeed's
`write_vhost_conf` already adds one, and the dotfile-deny context must keep
its `(?!well-known)` exclusion.

## Wiring status

* tos-litespeed (`index.cgi` `write_vhost_conf`): the aliases and rules can
  be appended to the `vhAliases` line and to `$rewrite_rules`. That change
  has not been made yet.
* apache2ols / native loader (`src/main/apacheconf.cpp`): cPanel's own
  `ServerAlias cpanel.x webmail.x ...` lines already come through as
  aliases. The loader should also turn cPanel's proxy `RewriteRule ... [P]`
  into these named backends. That is still open on M2.

## Not verified

None of this has been run against a real cPanel/cpsrvd. Four things still
need a live test:

* cpsrvd's answer to a proxied request whose `Host` is `cpanel.<domain>`.
* What happens with "Always redirect to SSL" turned on.
* The autodiscover CGI path.
* An AutoSSL run where every SAN passes DCV, which is the exit criterion
  for M2.
