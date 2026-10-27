# OLS PRO — roadmap

Fork of [litespeedtech/openlitespeed](https://github.com/litespeedtech/openlitespeed)
(`master` = pristine upstream mirror, `pro` = our work; sync with
`git fetch upstream && git merge upstream/master` into `pro`).
Licence stays GPLv3. Everything we add lives under `pro/` or in clearly marked
new files (`apacheconf*`, `mod_*pro*`) to keep upstream merges cheap.

## Why

Production evidence (artcp, chpro, ctech, onnorokomv3, Oct 2026): LiteSpeed
Enterprise licences die, OLS is the fallback, and stock OLS is *not* a drop-in
on cPanel. Gaps we hit for real (not hypothetical):

| # | Gap vs Enterprise on cPanel | Today's workaround (tos-litespeed plugin) |
|---|-----------------------------|-------------------------------------------|
| G1 | No native `httpd.conf` / EA4 `userdata` loader | Plugin generates OLS vhost files; new account needs manual Sync |
| G2 | cPanel proxy subdomains (`cpanel.`/`webmail.`/`whm.`/`autodiscover.`) return OLS welcome page → AutoSSL DCV breaks | none |
| G3 | `.htaccess` gaps: `[R=404]`, `[G]`, `[F]` flag handling, `php_value` family, `<IfModule>` nesting | plugin lifts rules into vhost conf |
| G4 | cPanel `ssl_redirect` lives in userdata, not `.htaccess` | plugin lifts it |
| G5 | No WAF parity (Imunify/Comodo/OWASP rulesets, `WordPressProtect`) | none |
| G6 | `/sitemap.xml` returns LSCache-hit 404 on ~65 Rank Math sites (root cause unknown) | none |
| G7 | No account-create/remove hook → vhost appears only after sync | cron/manual |
| G8 | Per-account resource limits (LVE/cgroup v2) not wired to suEXEC | none |
| G9 | No first-class observability (per-vhost req/s, 5xx, cache hit, slow-PHP) | sam "OLS PRO" monitor (external) |
| G10 | Licence-tool interference (`esp litespeed cron`, `socket.so` shim) segfaults OLS | `chattr +i`, manual |

## Milestones

**M0 — Reproducible build (this week)**
AlmaLinux 9 container build (`pro/docker/`), CI on GitHub Actions for
x86_64 + aarch64, RPM/DEB packaging with a distinct package name (`olspro`)
that *conflicts* with `openlitespeed` and never touches `/usr/local/lsws.ent`.
Exit: `docker build` → working `openlitespeed` binary that serves a static file.

**M1 — Native Apache config loader (G1, G4, G7)**
`src/main/apacheconf.{h,cpp}`: parse `httpd.conf` + `Include` globs and emit the
same `XmlNode` tree `plainconf` produces, so the rest of the server is untouched.
Wired in at `HttpConfigLoader::loadConfigFile`. Subset first:
`Listen`, `<VirtualHost>`, `ServerName/Alias`, `DocumentRoot`, `SuexecUserGroup`,
`SSLCertificate*`, `ErrorLog/CustomLog`, `Redirect*`, `ScriptAlias`,
`SetHandler proxy:unix:…|fcgi://` (EA4 PHP-FPM), `AddHandler`, `<Directory>`,
`<IfModule>`, `Header`, `RewriteRule/Cond`.
Then SIGHUP / inotify reload so a new cPanel account is live without a sync.
Exit: artcp's real `httpd.conf` (124 vhosts) loads with zero unsupported
directives that matter, vhost-for-vhost parity vs Apache on the existing 124-site
comparison harness.

**M2 — cPanel proxy subdomains + AutoSSL (G2)**
Built-in reverse-proxy contexts for `cpanel|webmail|whm|cpcalendars|cpcontacts`
→ cpsrvd 2082/2083/2086/2087/2095/2096, `/.well-known/cpanel-dcv` and
`pki-validation` passthrough. Exit: AutoSSL renews a cert with all SANs.

**M3 — `.htaccess` parity (G3)**
Fix flag handling, add the missing directives, fuzz against the WordPress
plugin ecosystem's top-100 `.htaccess` files (corpus checked in under `test/`).

**M4 — Security (G5, G10)**
ModSecurity v3 build with OWASP CRS + Comodo rules loadable from cPanel's
paths; per-IP/per-vhost rate limiting; `WordPressProtect`-equivalent
(xmlrpc/login brute-force throttling) as a native module; refuse to load
`socket.so`-style LD_PRELOAD shims (G10).

**M5 — Performance (the "beat Enterprise" part)**
Benchmarks are the definition of done, not adjectives. Baseline vs
LSWS Enterprise 6.x and vs Nginx on identical hardware: static, PHP-FPM/LSAPI
WordPress, HTTP/2, HTTP/3, TLS handshakes/s. Targets: ≥ parity everywhere,
lead on cached-WordPress p99. Work items: LSCache correctness (G6), ESI,
io_uring path for static files, TLS session-ticket sharing, memory/connection
footprint per idle keep-alive.

**M6 — Isolation & observability (G8, G9)**
cgroup v2 per-account limits tied to suEXEC; Prometheus endpoint with per-vhost
metrics; consumed by sam's OLS PRO page.

## Rules of engagement

- Never deploy to a production box from this repo directly. Build → stage on
  `:20080/:20443` (artcp precedent) → plugin switch with auto-rollback.
- Every milestone ships behind a config flag defaulting to upstream behaviour.
- Each feature lands with a test in `pro/tests/` (parser fixtures, curl-based
  parity harness).

## Known upstream bugs (found by the OLS PRO smoke suite)

- **Directory index checked against the directory's mode.** With no
  `fileAccessControl` block (built-in `restrictedPermissionMask` 041111) and a
  single-entry `indexFiles index.html`, `GET /` returns 403 ("Permission of file
  .../index.html does not meet the requirements...") while `GET /index.html`
  returns 200; `indexFiles index.php, index.html` returns 200. Masked in stock
  installs because the shipped config sets the masks to 000. Repro: 2026-10-27 in
  olspro-dev. Suspect the URL static-file cache path (`HttpReq` ~4417
  `getUrlStaticFileData`, `HttpSession` ~2871) carrying the directory stat;
  not yet root-caused.

## Status 2026-10-27 (sprint: 9 features, each independently reviewed + fixed + re-checked)

Verified on a real build (olspro-dev, AlmaLinux 9, gcc 11): `pro/tests/smoke/smoke.sh`
15/15 PASS — static 200, `-t` clean, mod_bruteguard 429 + Retry-After with no
worker crash (the first version segfaulted the server: hook returned 429 instead
of LSI_ERROR), Apache-converted cPanel fixture serves 301 → https 200 with a
verified chain.

| Gap | Delivered | Verified how | Not yet |
|-----|-----------|--------------|---------|
| G1 | `src/main/apacheconf_loader.*`: env `OLSPRO_APACHE_CONF` renders into `$SERVER_ROOT/apache-generated/` (root-owned, O_NOFOLLOW, atomic generations) | compile + Mac unit tests | not exercised against a real cPanel httpd.conf |
| G2/G7 | `pro/cpanel/`: standardized hooks, debounce, validated symlink-swap + rollback, service-subdomain proxy generator | bash -n, describe JSON, sandbox tree | never run on cPanel |
| G3 | `[F]`/`[G]`/`[R=4xx]` Apache parity, behind `OLSPRO_REWRITE_STATUS_PARITY=1` | parse-level tests on built objects | no request-level test |
| G5 | `mod_bruteguard`: shared-memory counters across workers, LRU-bounded, allowlist, extra paths | smoke 429 path | per-vhost keys, xmlrpc-specific limit |
| G9 | `pro/tools/ols-exporter/`: Prometheus exporter, per-worker counters | 12 unit tests | not checked against LSWS Enterprise `.rtreport` |
| G10 | `pro/security/olspro-shimguard.sh` check/fix/watch + systemd units | 28 assertions on fake tree | installer does not call `record` after upgrades |
| ESI | `src/modules/cache/esi/`: streaming parser/assembler with input/CPU limits | 82 tests incl. ASan/UBSan | not wired into cache.cpp |
| CPNS | `pro/cpns/`: integration contract + pre-reload validator (JSON) | fake layout | CPNS does not call it yet |
