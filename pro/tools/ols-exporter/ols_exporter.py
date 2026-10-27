#!/usr/bin/env python3
#############################################################################
#    OLS PRO - Prometheus exporter for OpenLiteSpeed .rtreport files.       #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
"""Expose OpenLiteSpeed real-time stats (.rtreport*) as Prometheus metrics.

stdlib only, python3.6+ (CentOS 7 rh-python36, AlmaLinux 8/9).

OLS writes one report per worker process roughly every second:
    <statdir>/.rtreport          (process 1)
    <statdir>/.rtreport.<N>      (process N, multi-process mode)
The writer is HttpServerImpl::generateRTReport() in src/main/httpserver.cpp,
vhost lines come from src/http/httpvhostlist.cpp, EXTAPP lines from
src/extensions/extworker.cpp. The "*.json" twins and "*.tmp" in-flight files
are ignored.

Aggregation: gauges are summed over all fresh worker reports. Counters
(*_total) are NOT summed: each worker's cumulative value is exported as its
own series with a process="N" label, so a worker (or one of its EXTAPP lines)
dropping out for a scrape, or being replaced on graceful restart, can never
make a series go backwards. Query with sum(rate(ols_requests_total[5m])).
Negative 32-bit totals (OLS keeps them in signed ints) are read as uint32.

Values may be integers (OLS writes %d) or decimals (LiteSpeed Enterprise
style per-second fields, e.g. "REQ_PER_SEC: 25.4"); anything that does not
parse is counted in ols_exporter_parse_errors. The decimal path is covered by
a synthetic fixture only; it has not been checked against a real LSWS
Enterprise .rtreport yet.

Cardinality: per vhost 3 + 3x2 series (+ 1 + 3 counters per worker), per
external app 7 gauges (+ 1 counter per worker). On hosts with thousands of
vhosts use --no-vhost-metrics, --vhost-include/--vhost-exclude or
--skip-idle-vhosts.

Security: /metrics exposes every hosted vhost name and its traffic. On
shared hosting any local user can reach 127.0.0.1, so set --auth-token-file
(clients send "Authorization: Bearer <token>") and/or restrict the port with
an owner match, e.g.
    nft add rule inet filter output tcp dport 9101 meta skuid != { 0, prometheus } drop

Usage:
    ols_exporter.py [--listen 127.0.0.1] [--port 9101] [--dir /tmp/lshttpd]
                    [--auth-token-file /etc/ols-exporter/token]
    ols_exporter.py --once      # print metrics to stdout and exit
"""

import argparse
import glob
import hmac
import math
import os
import re
import socket
import socketserver
import stat
import sys
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

VERSION = "0.2.0"
DEFAULT_DIR = "/tmp/lshttpd"
REPORT_RE = re.compile(r"^\.rtreport(?:\.(\d+))?$")
UPTIME_RE = re.compile(r"(?:(\d+)\s+days?\s+)?(\d+):(\d+):(\d+)")
REQ_RATE_RE = re.compile(r"^REQ_RATE \[(.*)\]: (.*)$")
EXTAPP_RE = re.compile(r"^EXTAPP \[(.*?)\] \[(.*?)\] \[(.*)\]: (.*)$")
INT_RE = re.compile(r"^[-+]?\d+$")
COUNTER_PREFIXES = ("TOT_", "TOTAL_")
UINT32 = 0xFFFFFFFF

# rtreport key -> cache label for hit metrics
CACHE_KEYS = (
    ("public", "PUB_CACHE_HITS_PER_SEC", "TOTAL_PUB_CACHE_HITS"),
    ("private", "PRIVATE_CACHE_HITS_PER_SEC", "TOTAL_PRIVATE_CACHE_HITS"),
    ("static", "STATIC_HITS_PER_SEC", "TOTAL_STATIC_HITS"),
)

# Connection gauges: rtreport key -> metric suffix
CONN_KEYS = (
    ("MAXCONN", "max_connections", "Configured max plain connections."),
    ("MAXSSL_CONN", "max_ssl_connections",
     "Configured max SSL connections."),
    ("PLAINCONN", "plain_connections", "Open plain (non-SSL) connections."),
    ("SSLCONN", "ssl_connections", "Open SSL connections."),
    ("IDLECONN", "idle_connections", "Idle keep-alive connections."),
    ("AVAILCONN", "available_connections",
     "Remaining plain connection slots."),
    ("AVAILSSL", "available_ssl_connections",
     "Remaining SSL connection slots."),
)

# BPS_* values are KB/s (HttpStats bytes / 1024 per 1s interval).
BPS_KEYS = (
    ("BPS_IN", "network_receive_bytes_per_second",
     "Bytes/s received, all listeners (OLS reports KB/s; converted)."),
    ("BPS_OUT", "network_transmit_bytes_per_second",
     "Bytes/s sent, all listeners (OLS reports KB/s; converted)."),
    ("SSL_BPS_IN", "ssl_network_receive_bytes_per_second",
     "Bytes/s received on SSL listeners (OLS reports KB/s; converted)."),
    ("SSL_BPS_OUT", "ssl_network_transmit_bytes_per_second",
     "Bytes/s sent on SSL listeners (OLS reports KB/s; converted)."),
)

EXTAPP_KEYS = (
    ("CMAXCONN", "max_connections", "gauge",
     "Configured max connections of the external app."),
    ("EMAXCONN", "effective_max_connections", "gauge",
     "Effective connection pool max."),
    ("POOL_SIZE", "pool_size", "gauge", "Connections currently in pool."),
    ("INUSE_CONN", "busy_connections", "gauge", "Connections in use."),
    ("IDLE_CONN", "idle_connections", "gauge", "Idle pooled connections."),
    ("WAITQUE_DEPTH", "wait_queue_depth", "gauge",
     "Requests waiting for a free connection."),
    ("REQ_PER_SEC", "requests_per_second", "gauge",
     "Requests/s to the external app."),
    ("TOT_REQS", "requests_total", "counter",
     "Requests sent to the external app since worker start."),
)


def _to_num(value):
    """'12' -> 12, '25.4' -> 25.4; raises ValueError on anything else."""
    text = value.strip()
    if INT_RE.match(text):
        return int(text)
    num = float(text)  # ValueError on junk / empty
    if math.isnan(num) or math.isinf(num):
        raise ValueError(text)
    return num


def parse_kv(text, errors=None):
    """Parse 'KEY: v, KEY2: v2' into a dict of numbers.

    Values that do not parse are skipped (not reported as 0) and their keys
    appended to `errors` when given.
    """
    out = {}
    for part in text.split(","):
        if ":" not in part:
            continue
        key, _, val = part.partition(":")
        key = key.strip()
        if not key:
            continue
        try:
            num = _to_num(val)
        except (ValueError, AttributeError):
            if errors is not None:
                errors.append(key)
            continue
        if (isinstance(num, int) and num < 0
                and key.startswith(COUNTER_PREFIXES)):
            # OLS keeps totals in signed 32-bit ints; read them as uint32.
            num &= UINT32
        out[key] = num
    return out


def parse_uptime(text):
    m = UPTIME_RE.search(text)
    if not m:
        return 0
    days = int(m.group(1) or 0)
    return days * 86400 + int(m.group(2)) * 3600 + int(m.group(3)) * 60 \
        + int(m.group(4))


def parse_report(text):
    """Parse one .rtreport body. Returns a dict, never raises on junk."""
    rep = {
        "version": "",
        "uptime": 0,
        "server": {},
        "req": {},
        "vhosts": {},
        "extapps": {},
        "blocked_ips": set(),
        "complete": False,
        "value_errors": 0,
    }
    errs = []
    for raw in text.splitlines():
        line = raw.strip()
        if not line:
            continue
        if line == "EOF":
            rep["complete"] = True
        elif line.startswith("VERSION:"):
            rep["version"] = line[len("VERSION:"):].strip()
        elif line.startswith("UPTIME:"):
            rep["uptime"] = parse_uptime(line[len("UPTIME:"):])
        elif line.startswith("BPS_IN:") or line.startswith("MAXCONN:"):
            rep["server"].update(parse_kv(line, errs))
        elif line.startswith("REQ_RATE ["):
            m = REQ_RATE_RE.match(line)
            if not m:
                continue
            name, kv = m.group(1), parse_kv(m.group(2), errs)
            if name == "":
                rep["req"] = kv
            else:
                rep["vhosts"][name] = kv
        elif line.startswith("EXTAPP ["):
            m = EXTAPP_RE.match(line)
            if m:
                key = (m.group(1), m.group(2), m.group(3))
                rep["extapps"][key] = parse_kv(m.group(4), errs)
        elif line.startswith("BLOCKED_IP:"):
            ips = line[len("BLOCKED_IP:"):].split(",")
            rep["blocked_ips"].update(ip.strip() for ip in ips if ip.strip())
    rep["value_errors"] = len(errs)
    return rep


def find_reports(stat_dir):
    """Return [(process_no, path)] for .rtreport and .rtreport.N files."""
    found = {}
    for path in glob.glob(os.path.join(stat_dir, ".rtreport*")):
        m = REPORT_RE.match(os.path.basename(path))
        if not m:
            continue
        proc = int(m.group(1) or 1)
        real = os.path.realpath(path)
        found.setdefault(real, (proc, path))
    return sorted(found.values())


def _sum_into(dst, src):
    for k, v in src.items():
        dst[k] = dst.get(k, 0) + v


def collect(stat_dir, max_age=30.0, now=None):
    """Read and aggregate all process reports in stat_dir."""
    if now is None:
        now = time.time()
    agg = {
        "processes": [],          # (proc, age_seconds, fresh)
        "version": "",
        "uptime": 0,
        "server": {},
        "req": {},
        "vhosts": {},
        "extapps": {},
        "blocked_ips": set(),
        "parse_errors": 0,
        # per fresh worker: (proc, req, vhosts, extapps) for *_total series
        "per_process": [],
    }
    for proc, path in find_reports(stat_dir):
        try:
            age = max(0.0, now - os.stat(path).st_mtime)
            with open(path, "r", errors="replace") as fh:
                rep = parse_report(fh.read())
        except (IOError, OSError):
            agg["parse_errors"] += 1
            continue
        fresh = age <= max_age and rep["complete"]
        if not rep["complete"]:
            agg["parse_errors"] += 1
        agg["parse_errors"] += rep["value_errors"]
        agg["processes"].append((proc, age, fresh))
        if not fresh:
            continue
        if rep["version"]:
            agg["version"] = rep["version"]
        agg["uptime"] = max(agg["uptime"], rep["uptime"])
        _sum_into(agg["server"], rep["server"])
        _sum_into(agg["req"], rep["req"])
        for name, kv in rep["vhosts"].items():
            _sum_into(agg["vhosts"].setdefault(name, {}), kv)
        for key, kv in rep["extapps"].items():
            dst = agg["extapps"].setdefault(key, {})
            for k, v in kv.items():
                # pool limits are per-worker config: report max, sum the rest
                if k in ("CMAXCONN",):
                    dst[k] = max(dst.get(k, 0), v)
                else:
                    dst[k] = dst.get(k, 0) + v
        agg["blocked_ips"].update(rep["blocked_ips"])
        agg["per_process"].append(
            (proc, rep["req"], rep["vhosts"], rep["extapps"]))
    return agg


def _esc(value):
    return str(value).replace("\\", "\\\\").replace("\n", "\\n") \
        .replace('"', '\\"')


def _labels(labels):
    if not labels:
        return ""
    return "{" + ",".join('%s="%s"' % (k, _esc(v)) for k, v in labels) + "}"


def _fmt(value):
    if isinstance(value, float):
        if value == int(value):
            return str(int(value))
        return repr(round(value, 6))
    return str(value)


class _Out(object):
    def __init__(self):
        self.lines = []

    def family(self, name, mtype, help_text, samples):
        """samples: list of (labels_tuple_list, value)."""
        self.lines.append("# HELP %s %s" % (name, help_text))
        self.lines.append("# TYPE %s %s" % (name, mtype))
        for labels, value in samples:
            self.lines.append("%s%s %s" % (name, _labels(labels),
                                           _fmt(value)))

    def text(self):
        return "\n".join(self.lines) + "\n"


class RenderOptions(object):
    """Cardinality controls for render()."""

    def __init__(self, vhost_metrics=True, vhost_include=None,
                 vhost_exclude=None, skip_idle_vhosts=False):
        self.vhost_metrics = vhost_metrics
        self.vhost_include = re.compile(vhost_include) if vhost_include \
            else None
        self.vhost_exclude = re.compile(vhost_exclude) if vhost_exclude \
            else None
        self.skip_idle_vhosts = skip_idle_vhosts

    def want_vhost(self, name):
        """Filter for vhost-labelled series. '' (server level) always kept."""
        if name == "":
            return True
        if self.vhost_include and not self.vhost_include.search(name):
            return False
        if self.vhost_exclude and self.vhost_exclude.search(name):
            return False
        return True


def _idle(kv):
    return not (kv.get("REQ_PROCESSING", 0) or kv.get("REQ_PER_SEC", 0)
                or kv.get("TOT_REQS", 0))


def render(agg, opts=None):
    """Render aggregated stats in Prometheus text format 0.0.4."""
    if opts is None:
        opts = RenderOptions()
    o = _Out()
    fresh = [p for p in agg["processes"] if p[2]]
    o.family("ols_up", "gauge",
             "1 if at least one fresh, complete .rtreport was read.",
             [([], 1 if fresh else 0)])
    o.family("ols_processes", "gauge",
             "Worker processes with a fresh .rtreport.",
             [([], len(fresh))])
    o.family("ols_report_age_seconds", "gauge",
             "Seconds since each worker last wrote its .rtreport.",
             [([("process", p)], round(age, 3))
              for p, age, _ in agg["processes"]])
    o.family("ols_exporter_parse_errors", "gauge",
             "Unreadable/truncated report files plus unparseable values "
             "this scrape.",
             [([], agg["parse_errors"])])
    if not fresh:
        return o.text()

    per_proc = sorted(agg.get("per_process", []), key=lambda x: x[0])

    o.family("ols_info", "gauge", "OpenLiteSpeed build info.",
             [([("version", agg["version"])], 1)])
    o.family("ols_uptime_seconds", "gauge", "Server uptime.",
             [([], agg["uptime"])])

    srv = agg["server"]
    for key, suffix, help_text in BPS_KEYS:
        o.family("ols_" + suffix, "gauge", help_text,
                 [([], srv.get(key, 0) * 1024)])
    for key, suffix, help_text in CONN_KEYS:
        o.family("ols_" + suffix, "gauge", help_text,
                 [([], srv.get(key, 0))])

    req = agg["req"]
    o.family("ols_requests_processing", "gauge",
             "Requests currently being processed.",
             [([], req.get("REQ_PROCESSING", 0))])
    o.family("ols_requests_per_second", "gauge",
             "Requests/s over the last report interval.",
             [([], req.get("REQ_PER_SEC", 0))])
    o.family("ols_requests_total", "counter",
             "Requests served since worker start, per worker process "
             "(use sum(rate(...))).",
             [([("process", p)], r.get("TOT_REQS", 0))
              for p, r, _, _ in per_proc if "TOT_REQS" in r])
    o.family("ols_cache_hits_per_second", "gauge",
             "Cache hits/s by cache type.",
             [([("cache", c)], req.get(ps, 0)) for c, ps, _ in CACHE_KEYS])
    o.family("ols_cache_hits_total", "counter",
             "Cache hits since worker start by cache type, per worker "
             "process.",
             [([("cache", c), ("process", p)], r.get(tot, 0))
              for p, r, _, _ in per_proc for c, _, tot in CACHE_KEYS
              if tot in r])

    if opts.vhost_metrics:
        vh = [(n, kv) for n, kv in sorted(agg["vhosts"].items())
              if opts.want_vhost(n)
              and not (opts.skip_idle_vhosts and _idle(kv))]
        keep = set(n for n, _ in vh)
        o.family("ols_vhost_requests_processing", "gauge",
                 "Requests in progress per virtual host.",
                 [([("vhost", n)], kv.get("REQ_PROCESSING", 0))
                  for n, kv in vh])
        o.family("ols_vhost_requests_per_second", "gauge",
                 "Requests/s per virtual host.",
                 [([("vhost", n)], kv.get("REQ_PER_SEC", 0)) for n, kv in vh])
        o.family("ols_vhost_cache_hits_per_second", "gauge",
                 "Cache hits/s per virtual host and cache type.",
                 [([("vhost", n), ("cache", c)], kv.get(ps, 0))
                  for n, kv in vh for c, ps, _ in CACHE_KEYS])
        pvh = [(p, n, kv) for p, _, vhosts, _ in per_proc
               for n, kv in sorted(vhosts.items()) if n in keep
               and not (opts.skip_idle_vhosts and _idle(kv))]
        o.family("ols_vhost_requests_total", "counter",
                 "Requests since worker start per virtual host, per worker "
                 "process.",
                 [([("vhost", n), ("process", p)], kv.get("TOT_REQS", 0))
                  for p, n, kv in pvh if "TOT_REQS" in kv])
        o.family("ols_vhost_cache_hits_total", "counter",
                 "Cache hits since worker start per virtual host and type, "
                 "per worker process.",
                 [([("vhost", n), ("cache", c), ("process", p)],
                   kv.get(tot, 0))
                  for p, n, kv in pvh for c, _, tot in CACHE_KEYS
                  if tot in kv])

    ea = [(k, kv) for k, kv in sorted(agg["extapps"].items())
          if opts.want_vhost(k[1])]
    for key, suffix, mtype, help_text in EXTAPP_KEYS:
        if mtype == "counter":
            samples = [([("type", t), ("vhost", v), ("app", a),
                         ("process", p)], kv.get(key, 0))
                       for p, _, _, extapps in per_proc
                       for (t, v, a), kv in sorted(extapps.items())
                       if key in kv and opts.want_vhost(v)]
            help_text += " Per worker process."
        else:
            samples = [([("type", t), ("vhost", v), ("app", a)],
                        kv.get(key, 0)) for (t, v, a), kv in ea]
        o.family("ols_extapp_" + suffix, mtype, help_text, samples)

    o.family("ols_blocked_ips", "gauge",
             "Client IPs currently blocked by OLS per-client throttling.",
             [([], len(agg["blocked_ips"]))])
    return o.text()


def _bearer_ok(header, token):
    if not token:
        return True
    if not header:
        return False
    scheme, _, cred = header.strip().partition(" ")
    if scheme.lower() != "bearer":
        return False
    return hmac.compare_digest(cred.strip().encode("utf-8"),
                               token.encode("utf-8"))


class _Handler(BaseHTTPRequestHandler):
    stat_dir = DEFAULT_DIR
    max_age = 30.0
    auth_token = None
    render_opts = None
    server_version = "ols-exporter/" + VERSION

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        extra = []
        if path == "/metrics":
            if not _bearer_ok(self.headers.get("Authorization"),
                              self.auth_token):
                body, code, ctype = "unauthorized\n", 401, "text/plain"
                extra.append(("WWW-Authenticate",
                              'Bearer realm="ols-exporter"'))
            else:
                try:
                    body = render(collect(self.stat_dir, self.max_age),
                                  self.render_opts)
                    code = 200
                except Exception as exc:  # never kill the server on a scrape
                    body = "# exporter error: %s\n" % _esc(exc)
                    code = 500
                ctype = "text/plain; version=0.0.4; charset=utf-8"
        elif path in ("/", "/healthz"):
            body = "ols-exporter %s: see /metrics\n" % VERSION
            code, ctype = 200, "text/plain; charset=utf-8"
        else:
            body, code, ctype = "not found\n", 404, "text/plain"
        data = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for name, value in extra:
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, fmt, *args):  # quiet; journald gets errors only
        pass


class _ThreadingServer(socketserver.ThreadingMixIn, HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def make_server(host, port, handler=_Handler):
    """Bind an HTTP server on host:port, IPv4 or IPv6 (e.g. '::1')."""
    infos = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM, 0,
                               socket.AI_PASSIVE)
    family = infos[0][0]
    cls = type("_FamilyServer", (_ThreadingServer,),
               {"address_family": family})
    return cls((host, port), handler)


def load_token(path):
    """Read a bearer token; warn if group/other can read the file."""
    st = os.stat(path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        sys.stderr.write("ols-exporter: warning: %s is readable by group/"
                         "other; chmod 0600 it\n" % path)
    with open(path, "r") as fh:
        token = fh.read().strip()
    if not token:
        raise ValueError("auth token file %s is empty" % path)
    return token


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--listen", default="127.0.0.1",
                    help="address to bind, IPv4 or IPv6 (default "
                    "%(default)s)")
    ap.add_argument("--port", type=int, default=9101)
    ap.add_argument("--dir", default=DEFAULT_DIR,
                    help="directory holding .rtreport* (default %(default)s)")
    ap.add_argument("--max-age", type=float, default=30.0,
                    help="ignore reports older than this many seconds")
    ap.add_argument("--auth-token-file",
                    help="require 'Authorization: Bearer <token>' on "
                    "/metrics; token read from this file (mode 0600)")
    ap.add_argument("--no-vhost-metrics", action="store_true",
                    help="do not export per-vhost ols_vhost_* series")
    ap.add_argument("--vhost-include", metavar="REGEX",
                    help="only export vhosts matching this regex "
                    "(vhost and extapp series)")
    ap.add_argument("--vhost-exclude", metavar="REGEX",
                    help="drop vhosts matching this regex")
    ap.add_argument("--skip-idle-vhosts", action="store_true",
                    help="omit vhosts with no requests at all (0 in-flight,"
                    " 0 rps, 0 total)")
    ap.add_argument("--once", action="store_true",
                    help="print metrics once to stdout and exit")
    args = ap.parse_args(argv)

    try:
        opts = RenderOptions(not args.no_vhost_metrics, args.vhost_include,
                             args.vhost_exclude, args.skip_idle_vhosts)
    except re.error as exc:
        ap.error("bad vhost regex: %s" % exc)

    if args.once:
        sys.stdout.write(render(collect(args.dir, args.max_age), opts))
        return 0

    _Handler.stat_dir = args.dir
    _Handler.max_age = args.max_age
    _Handler.render_opts = opts
    if args.auth_token_file:
        try:
            _Handler.auth_token = load_token(args.auth_token_file)
        except (IOError, OSError, ValueError) as exc:
            sys.stderr.write("ols-exporter: %s\n" % exc)
            return 2
    httpd = make_server(args.listen, args.port)
    sys.stderr.write("ols-exporter %s listening on %s:%d, dir=%s, auth=%s\n"
                     % (VERSION, args.listen, args.port, args.dir,
                        "bearer" if _Handler.auth_token else "none"))
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
