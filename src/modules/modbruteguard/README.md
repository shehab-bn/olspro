# mod_bruteguard (OLS PRO)

Native login / xmlrpc brute-force throttle. Counts **POST** requests per client
(IPv4 address, or IPv6 /64) against credential endpoints and answers `429 Too Many Requests` with a
`Retry-After` header once the per-window limit is exceeded. It runs at
`RCVD_REQ_HEADER` (hook priority EARLY), so a credential-stuffing flood is
rejected before PHP or the database is touched.

## How counting works

- Only `POST` is counted. `GET` of a login page is never throttled.
- A path is guarded when a guarded tail occurs in it and is followed by the end
  of the path or by `/`. So `/wp-login.php`, `/blog/wp-login.php` and the
  PATH_INFO forms `/xmlrpc.php/x` and `/wp-login.php/` all count. The query
  string is stripped first, so `/wp-login.php?action=lostpassword` counts as
  `/wp-login.php`.
- For guarded tails under `/wp-json/`, the WordPress query form is guarded
  too: `/?rest_route=/jwt-auth/v1/token` (percent-encoded or not).
- Fixed window per client: after `OLSPRO_BG_LIMIT` POSTs inside one
  `OLSPRO_BG_WINDOW`-second window, the client is banned for `OLSPRO_BG_BAN`
  seconds. Every guarded POST during the ban gets 429 and
  `Retry-After: <seconds left + 1>`.
- **Client key:** IPv4 clients are counted per address. IPv6 clients are
  counted per **/64**, because one host or subscriber normally owns a whole
  /64 and could otherwise rotate addresses to get a fresh counter for every
  request. IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is treated as IPv4.
- **Global across workers and vhosts:** counters live in an LRU
  shared-memory hash (pool `olsprobg`, hash `bglru`, in the server's normal SHM
  directory). Every worker process shares one counter per client, so the limit
  is the real limit, not `N workers x limit`. The counter is also shared by
  **every vhost on the box**: on shared hosting, 10 POSTs/min from one IP to
  *any* site trips the ban for all sites. See "False positives" below.
- Each entry is a fixed 16-byte value. The window id and the count are packed
  into one 32-bit word and updated with a single CAS, so a window rollover and
  an increment cannot interleave: no lost increments and no stale-window hits
  counted against the new window. `ls_shmhash_get()` does find-or-create under
  the hash's own lock, so concurrent first hits from one client land on a
  single entry.
- **Bounded table:** each worker trims entries whose window and ban are both
  over (at most every 10 s). When a new entry pushes the table past
  `OLSPRO_BG_MAXENTRIES`, the least recently used entries are evicted down to
  90% of the cap. A client that keeps hitting a guarded path stays "recently
  used" and keeps its ban. An idle banned client can lose its ban early during
  a flood of new clients, which is the intended trade-off for bounded memory.
- **Fallback:** if shared memory cannot be opened at start-up, or an entry
  cannot be created (pool full), the module uses per-process counters for that
  request (bounded by the same cap). The server never fails to start because
  of this module.
- The 429 is produced through the normal module-deny path (the hook returns
  `LSI_ERROR` after setting status 429). `Retry-After` is added again when the
  error page's headers are sent, because the error page path resets response
  headers.

## Tunables

Set these in the environment of the OLS process, for example in a systemd
drop-in (`Environment=OLSPRO_BG_LIMIT=20`) or in `/usr/local/lsws/bin/lswsctrl`
before start. They are read once at module init. Restart the server to apply
a change.

| Variable | Default | Meaning |
|---|---|---|
| `OLSPRO_BG_LIMIT` | `10` | POSTs allowed per window per client before the ban (max 60000). |
| `OLSPRO_BG_WINDOW` | `60` | Window length in seconds. |
| `OLSPRO_BG_BAN` | `300` | Ban length in seconds once the limit is exceeded. |
| `OLSPRO_BG_MAXENTRIES` | `100000` | Max clients tracked in shared memory (min 100). Roughly 100 bytes each. LRU-evicted beyond. |
| `OLSPRO_BG_PATHS` | (none) | Extra comma-separated path **tails** to guard, added to the built-in list. Example: `/login,/api/auth/token,/index.php/admin`. |
| `OLSPRO_BG_ALLOW` | (none) | Comma-separated IPs or **CIDR ranges** (IPv4 and IPv6) that are never throttled. Example: `127.0.0.1,::1,203.0.113.0/24,2001:db8::/32`. Invalid entries are logged at start-up and ignored. |
| `OLSPRO_BG_OFF` | unset | Any value disables the module completely. |

Non-numeric or non-positive values for the numeric tunables fall back to the
default. Spaces around list items are trimmed and empty items are ignored.

Built-in guarded suffixes:

```
/wp-login.php
/xmlrpc.php
/administrator/index.php      (Joomla)
/user/login                   (Drupal)
/wp-json/jwt-auth/v1/token
```

## Client IP

The module uses the IP OLS reports for the session. Behind a load balancer or
CDN, configure OLS "Use Client IP in Header" / trusted proxies first. Otherwise
every request appears to come from the proxy, and the proxy gets banned.

**Do not use "Use Client IP in Header" = `Yes`** (trust the header from
anyone) on a server that is reachable directly. In that mode OLS takes the
client IP from `X-Forwarded-For` before this module runs, so an attacker can
send a random value on every request, get a fresh counter each time, and never
be throttled. Use `Trusted IP Only` with your proxy/CDN ranges in the trusted
list instead.

## False positives

Because the counter is per client for the whole server, sources that log in
to many sites from one IP can hit the limit legitimately: Jetpack (Automattic
posts to `xmlrpc.php` for every connected site, e.g. from `192.0.64.0/18`),
the WordPress mobile app behind CGNAT, office NAT, or a CDN whose real client
IP is not configured. Add such ranges to `OLSPRO_BG_ALLOW` (CIDR supported) or
raise `OLSPRO_BG_LIMIT`.

## Known limitations

- One limit for all guarded paths and all vhosts. There is no per-vhost key
  and no separate (higher) limit for `xmlrpc.php` yet.
- The window is a fixed, clock-aligned window, so a client can send up to
  `2 x LIMIT` POSTs across a window boundary before the ban.
- Expired entries are trimmed only while guarded POSTs keep arriving. The
  table never exceeds the cap, but an idle server keeps its last entries until
  the next guarded POST.
- v0.2 used a non-LRU hash named `bruteguard` in the same pool. It is no longer
  used and is not freed until the `olsprobg` SHM files are removed while the
  server is stopped.
- Settings are process-environment only. There is no per-vhost config or
  WebAdmin UI yet.
- The 429 response body is the server's default error page.

## Quick test

```sh
for i in $(seq 1 12); do
  curl -s -o /dev/null -w '%{http_code} ' -X POST http://127.0.0.1/wp-login.php
done; echo
# expect: 200/302 ... then 429 429 (with Retry-After)
```

With more than one worker (`httpdWorkers` > 1), the 429 should still begin at
request `LIMIT + 1`, because the counter is shared.
