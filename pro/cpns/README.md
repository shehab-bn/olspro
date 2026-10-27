# OLS PRO <-> CPNS (ToshostCP) integration

This directory describes the contract between OLS PRO and CPNS's OpenLiteSpeed driver,
and ships a read-only validator that CPNS can run before it reloads.

Source of truth for the CPNS side:
`cpns/internal/agent/webserver/litespeed/litespeed.go` and `siterules.go`.
Nothing here changes CPNS. The "Changes CPNS should adopt" section below lists proposals only.

## 1. Contract as CPNS implements it today

| Item | Value |
|------|-------|
| Server root | `config.Agent` root, normally `/usr/local/lsws` |
| Main config | `$ROOT/conf/httpd_config.conf` (CPNS does not regenerate it) |
| Managed include | `$ROOT/conf/toshostcp_vhosts.conf`. It holds every `virtualhost {}`, `listener toshostcpHTTP` (`*:80`) and `listener toshostcpHTTPS` (`*:443`, armed with the first SSL vhost's cert), plus the `toshostcp-acme` catch-all challenge vhost. |
| Wiring line | `include toshostcp_vhosts.conf` at top level of `httpd_config.conf`. **Use the bare name:** OLS resolves an include relative to the including file's directory, so `include conf/toshostcp_vhosts.conf` silently loads nothing. |
| Per-vhost config | `$ROOT/conf/vhosts/<domain>/vhconf.conf` plus `meta.json` (CPNS's sidecar; the include is rebuilt from all `meta.json`) |
| Per-vhost logs | `$VH_ROOT/logs/{error,access}.log` |
| Per-vhost includes (must exist) | `$ROOT/conf/toshostcp-siterules/<domain>.conf` (realms, error pages) and `$ROOT/conf/toshostcp-ipblock/<user>.conf` (IP blocker; also included inside each `context`) |
| Removed vhosts | moved to `$ROOT/conf/.toshostcp-removed/<domain>-<ns>` and restored if the config test fails |
| Writes | atomic (temp + rename), with snapshots of `vhconf.conf`, `meta.json`, the include and the snippets. Rolled back if the test fails. |
| Config test | `$ROOT/bin/openlitespeed -t`. Only `[ERROR]` lines mean failure. A non-zero exit that prints only `[WARN]`/`[NOTICE]` tags counts as pass, because stock OLS exits non-zero on a fresh box. Output with no severity tags means the binary did not run. |
| Apply | `$ROOT/bin/lswsctrl reload` when every declared port is already bound. Otherwise (a new listener) `lswsctrl restart`, then `systemctl restart lshttpd`, waiting 8 s after each to see whether the port is bound. |

### PHP handler model

There is one lsphp pool per vhost. CPNS does not use one shared pool per PHP version.

```
scripthandler { add lsapi:<domain>-lsphpXY php[,extra exts from .htaccess] }
extprocessor <domain>-lsphpXY {
  type lsapi
  address uds://tmp/lshttpd/<domain>-lsphpXY.sock     # created by OLS on first spawn
  maxConns N ; env PHP_LSAPI_CHILDREN=N              # same N; default 10
  env LSAPI_MAX_IDLE=…  env PHP_INI_SCAN_DIR=…        # optional
  autoStart 2 ; path $SERVER_ROOT/lsphpXY/bin/lsphp ; extUser <system user>
  runOnStartUp 1                                     # off on dense nodes
}
```

- Per-account `php_admin_value` values (`sendmail_path` = the mailgate, `session.save_path`, `open_basedir`) live in the vhost.
- Per-site `PHP_INI_SCAN_DIR` points at a directory CPNS renders.
- The socket does not exist until OLS spawns lsphp, so a missing socket is fine as long as its directory exists and `autoStart` is on.

## 2. `olspro-cpns-check.sh`: pre-reload validator

```
pro/cpns/olspro-cpns-check.sh [--root /usr/local/lsws] [--no-config-test] [--warn-days 14] [--strict]
```

The script is read-only: it writes nothing and reloads nothing. It prints one JSON document:

```json
{"ok":false,"tool":"olspro-cpns-check","version":1,"root":"/usr/local/lsws",
 "generated":"…Z","summary":{"ok":16,"warn":5,"fail":7,"skip":1},
 "checks":[{"status":"fail","check":"vhost.docroot","target":"bad.test",
            "detail":"docRoot /home/bad/public_html does not exist"}, …]}
```

Exit codes: `0` means no failures, `1` means at least one failure (with `--strict`, a warning also returns 1), and `2` means the tool could not run: a usage error (JSON `{"ok":false,"error":…}`) or an unusable server root (full JSON with a `server.root` fail).

| check | fails when |
|-------|-----------|
| `server.root` | `httpd_config.conf` is unreadable (exit 2) |
| `include.wired` | no top-level include resolves to `conf/toshostcp_vhosts.conf`. `include toshostcp_vhosts.conf`, the absolute path and `$SERVER_ROOT/conf/toshostcp_vhosts.conf` (any case) all pass; `include conf/toshostcp_vhosts.conf` fails. |
| `include.file` | a top-level include is missing, or uses a `$VAR` other than `$SERVER_ROOT/` (OLS logs "Can't resolve include file" and drops it). A wildcard include that matches nothing is a warning. |
| `config.test` | `openlitespeed -t` prints `[ERROR]`, cannot run, or times out / is killed (exit 124 or ≥128). Otherwise it is the same tolerance as CPNS `TestConfig()`. |
| `port.conflict` | two listeners of the same address family share a port and either has the same IP or the wildcard (`*`/`0.0.0.0`/`ANY` for IPv4, `[ANY]`/`[::]` for IPv6). `*:443` plus `[ANY]:443` is the normal dual-stack pair and passes. |
| `port.foreign` | `ss` shows a declared port held by something that is not lshttpd/openlitespeed |
| `port.bound` (warn) | a declared port is not listening, so CPNS must **restart**; a reload is not enough. If `ss` itself fails the check is `skip`, never "not listening". |
| `map.duplicate` (warn) | one listener maps the same hostname to two vhosts |
| `vhost.root` / `vhost.conf` / `vhost.docroot` | the directory or file is missing |
| `vhost.include` | an `include` in vhconf (siterules or ipblock) is missing, or uses `$VH_ROOT`/`$DOC_ROOT`, which OLS does not expand in includes |
| `extproc.socket` | the socket directory is missing, or the socket is missing while `autoStart` is 0. A missing `/tmp/lshttpd` is only a warning: OLS recreates it on start, and failing would block the restart that fixes it. |
| `extproc.binary` / `extproc.user` | the lsphp `path` is not executable, or `extUser` does not exist. Vhost-level processors fail; server-level ones in `httpd_config.conf` (stock `extprocessor lsphp`) only warn, because CPNS vhosts carry their own handler. |
| `ssl.cert` / `ssl.key` / `ssl.pair` | the cert or key is unreadable, the key cannot be parsed (corrupt, unsupported or passphrase-protected; never prompts), the cert is expired (`openssl x509 -checkend 0`), or the key does not match the cert. A cert expiring within `--warn-days` is a warning. |

Parser notes:
- It flattens OLS's block syntax and skips `<<<END_x … END_x` heredocs (rewrite rules).
- Directive values expand `$SERVER_ROOT`, `$VH_ROOT`, `$VH_NAME` and `$DOC_ROOT`.
- `include` (keyword matched in any case) is resolved like `plainconf::getIncludeFile()`: absolute, `$server_root/` in any case, otherwise relative to the including file's directory.
- It follows top-level includes one level deep, with glob support.
- Cost: one `flatten` + two `awk` passes per vhost, openssl results cached per file. About 15 ms per vhost (300 vhosts ≈ 4.7 s in the dev container).
- Needs bash 4.0 or newer; it avoids the bash < 4.4 `set -u` empty-array abort and `ss -H` (missing before iproute2 4.14), so it runs on EL7/CloudLinux 7.

## 3. Changes CPNS should adopt to use OLS PRO

1. **Run the validator before `lswsctrl reload`.** In `Reload()`, after `TestConfig()`, run `olspro-cpns-check.sh --no-config-test` (CPNS has just run `-t` itself).
   - Refuse the reload on `"ok":false`.
   - Surface `checks[].detail` in the task error. This catches what `-t` misses: missing docroots, deleted system users, dead lsphp binaries after a PHP removal, and expired or mismatched certs.
   - When any `port.bound` warning appears, use it as the restart-vs-reload signal instead of CPNS's own TCP probe.
2. **Detect OLS PRO:** treat it as present when `$ROOT/pro/` exists or when the `olspro` package is installed. Once OLS PRO's `-v` output carries a marker, use that too; it does not carry one yet, so this needs a small `printVersion()` change, not done here. Keep the stock OLS behaviour as the fallback.
3. **bruteguard (`modbruteguard`):** the variables are read from the environment of the **OLS process** at module init, so put them in the `lshttpd` systemd drop-in (`/etc/systemd/system/lshttpd.service.d/olspro.conf`, `Environment=…`, then `systemctl daemon-reload` + restart). Do not use the agent env file: it reaches OLS only when the agent itself cold-starts it, and CPNS's own `systemctl restart lshttpd` fallback drops it.
   - `OLSPRO_BG_LIMIT` (default 10)
   - `OLSPRO_BG_WINDOW` (seconds, default 60)
   - `OLSPRO_BG_BAN` (seconds, default 300)
   - `OLSPRO_BG_ALLOW`: comma-separated exact IPs never throttled. Put the panel, sam monitor and uptime-probe IPs here.
   - `OLSPRO_BG_OFF`: kill switch. The module checks only that the variable **exists**, so any value, including `0`, disables it. A panel toggle must **remove** the line to enable bruteguard; never write `OLSPRO_BG_OFF=0`.

   Add a panel toggle under Security. Counters live in a shared-memory hash, so `LIMIT` is the real per-IP limit across all workers; it falls back to per-process counting only if the SHM cannot be opened (logged at start). TosShield should stop rate-limiting `wp-login.php`/`xmlrpc.php` itself when bruteguard is on, so the two do not double-ban.
4. **Apache-generated include (`apache2ols`, `src/main/apacheconf.cpp`):** for imports from cPanel/Apache (cpmove), run `apache2ols` on the source `httpd.conf` once and diff the output against CPNS's own rendering as an import sanity check. Do not include it alongside `toshostcp_vhosts.conf`, because both would declare `*:80`/`*:443` listeners and `port.conflict` fires. CPNS must stay the single owner of the listeners.
5. **Metrics (roadmap G9):** until OLS PRO ships per-vhost metrics, read OLS's own real-time report at `/tmp/lshttpd/.rtreport*` for req/s, connections and per-vhost `REQ_RATE`. When OLS PRO metrics land, the agent should scrape them and feed sam's "OLS PRO" monitor, so it no longer has to probe 169 sites over HTTP (the probing caused the lsphp storm noted in `litespeed.go`).
6. **Per-vhost lsphp hygiene:** keep `maxConns` = `PHP_LSAPI_CHILDREN` (already done). When removing a PHP version, run the validator first: `extproc.binary` fails for every vhost-level processor still pointing at it and warns for a server-level one (target `server/<name>`). Processors defined anywhere other than `httpd_config.conf`, its top-level includes or a vhconf are not checked.

## 4. Verified / not verified

- **Verified** (in the `olspro-dev` container, AlmaLinux 9, bash 5.1, OpenSSL 3), with `bash -n` passing on Mac and in the container. The checker ran against a fake layout under `/root/cpnscheck-fake` and correctly reported:
  - a good vhost, with a heredoc rewrite block, a nested `context` include and a valid vhssl cert
  - a `*:8088` vs `0.0.0.0:8088` port conflict
  - a duplicate map
  - a listener cert expiring in 3 days
  - a missing docroot, a missing ipblock include, a missing socket dir, a missing lsphp binary and a missing extUser
  - a cert/key mismatch
  - unbound ports
- **Regression tests for the review fixes** (`/root/cpnscheck-fixtests.sh` in the container, 24/24 pass): `$SERVER_ROOT/` and `INCLUDE $server_root/` top-level includes are followed; `$FOO/…` and `conf/…` includes fail; `*:443` + `[ANY]:443` passes while `[::]:443` + `[ANY]:443` conflicts; a missing OLS tmp dir is a warning; a `-t` killed by a signal fails while warnings-only still passes; `--root`/`--warn-days` as the last argument exit 2; a missing root exits 2 with JSON; encrypted and garbage keys give `ssl.key` fail with no prompt and no bogus `ssl.pair`; a server-level `extprocessor lsphp` with a missing binary warns; a vhost `Include $VH_ROOT/…` fails; an empty config still prints JSON; a python listener on a declared port gives `port.foreign`.
- **Not verified:**
  - `config.test` against a real install, and a real 30 s timeout (the killed-by-signal path was tested)
  - the expired-cert branch (only near-expiry was exercised)
  - bash 4.2 / iproute2 4.11 on a real EL7 box (the code avoids both pitfalls, but it ran only on bash 5.1)
  - a real CPNS node's generated tree
