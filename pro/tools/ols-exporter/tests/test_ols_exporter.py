#############################################################################
#    OLS PRO - tests for ols_exporter.py (python3 -m unittest).             #
#    GPLv3, see GPL.txt                                                     #
#############################################################################
import os
import shutil
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import ols_exporter as ex  # noqa: E402

FIXTURES = os.path.join(HERE, "fixtures")


def _samples(text):
    """Parse exposition text into {('name', 'labels'): value} + TYPE map."""
    vals, types = {}, {}
    for line in text.splitlines():
        if line.startswith("# TYPE "):
            _, _, name, mtype = line.split(" ", 3)
            types[name] = mtype
        elif line and not line.startswith("#"):
            head, _, val = line.rpartition(" ")
            if "{" in head:
                name, labels = head.split("{", 1)
                labels = "{" + labels
            else:
                name, labels = head, ""
            vals[(name, labels)] = float(val)
    return vals, types


class FixtureDirMixin(object):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="olsexp-")
        for name in os.listdir(FIXTURES):
            src = os.path.join(FIXTURES, name)
            if os.path.isfile(src):
                shutil.copy(src, os.path.join(self.tmp, name))
        self.now = time.time()
        for name in os.listdir(self.tmp):
            os.utime(os.path.join(self.tmp, name), (self.now, self.now))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)


class ParseTest(unittest.TestCase):
    def test_single_report(self):
        with open(os.path.join(FIXTURES, ".rtreport")) as fh:
            rep = ex.parse_report(fh.read())
        self.assertTrue(rep["complete"])
        self.assertEqual(rep["version"], "LiteSpeed Web Server/Open/1.9.4")
        self.assertEqual(rep["uptime"], 2 * 86400 + 3 * 3600 + 4 * 60 + 5)
        self.assertEqual(rep["server"]["BPS_OUT"], 340)
        self.assertEqual(rep["server"]["SSLCONN"], 10)
        self.assertEqual(rep["req"]["TOT_REQS"], 123456)
        self.assertEqual(rep["vhosts"]["example.com"]["REQ_PER_SEC"], 20)
        self.assertIn('shop "a"', rep["vhosts"])
        key = ("LSAPI", "example.com", "lsphp82")
        self.assertEqual(rep["extapps"][key]["WAITQUE_DEPTH"], 2)
        self.assertIn(("LSAPI", "", "lsphp"), rep["extapps"])
        self.assertEqual(rep["blocked_ips"], {"192.0.2.10", "2001:db8::1"})

    def test_uptime_without_days(self):
        self.assertEqual(ex.parse_uptime(" 00:01:02"), 62)
        self.assertEqual(ex.parse_uptime(" 1 day 00:00:01"), 86401)

    def test_truncated_report_incomplete(self):
        rep = ex.parse_report("VERSION: x\nBPS_IN: 1, BPS_OUT: 2\n")
        self.assertFalse(rep["complete"])

    def test_find_reports_ignores_json_and_tmp(self):
        names = sorted(os.path.basename(p)
                       for _, p in ex.find_reports(FIXTURES))
        self.assertEqual(names, [".rtreport", ".rtreport.2"])


class ValueParseTest(unittest.TestCase):
    def test_decimal_values_kept(self):
        rep = ex.parse_report(
            "REQ_RATE []: REQ_PER_SEC: 25.4, TOT_REQS: 7\nEOF\n")
        self.assertEqual(rep["req"]["REQ_PER_SEC"], 25.4)
        self.assertEqual(rep["req"]["TOT_REQS"], 7)
        self.assertIsInstance(rep["req"]["TOT_REQS"], int)
        self.assertEqual(rep["value_errors"], 0)

    def test_junk_value_counted_not_zeroed(self):
        rep = ex.parse_report(
            "REQ_RATE []: REQ_PER_SEC: abc, TOT_REQS: 5, X: nan\nEOF\n")
        self.assertNotIn("REQ_PER_SEC", rep["req"])
        self.assertEqual(rep["req"]["TOT_REQS"], 5)
        self.assertEqual(rep["value_errors"], 2)

    def test_negative_total_read_as_uint32(self):
        rep = ex.parse_report(
            "REQ_RATE []: REQ_PROCESSING: 1, TOT_REQS: -2, "
            "TOTAL_STATIC_HITS: -1\nEOF\n")
        self.assertEqual(rep["req"]["TOT_REQS"], 2 ** 32 - 2)
        self.assertEqual(rep["req"]["TOTAL_STATIC_HITS"], 2 ** 32 - 1)

    def test_lsws_enterprise_style_report(self):
        d = os.path.join(FIXTURES, "lsws")
        agg = ex.collect(d, max_age=1e12)
        self.assertEqual(agg["parse_errors"], 0)
        vals, _ = _samples(ex.render(agg))
        self.assertEqual(vals[("ols_requests_per_second", "")], 25.4)
        self.assertEqual(
            vals[("ols_cache_hits_per_second", '{cache="static"}')], 4.6)
        self.assertEqual(vals[("ols_requests_total", '{process="1"}')],
                         15000)
        lbl = ('{type="LSAPI",vhost="APVH_example.com",'
               'app="example.com_lsphp"}')
        self.assertEqual(vals[("ols_extapp_requests_per_second", lbl)], 0.5)
        self.assertEqual(vals[("ols_blocked_ips", "")], 0)

    def test_parse_errors_reach_metric(self):
        tmp = tempfile.mkdtemp(prefix="olsexp-bad-")
        try:
            with open(os.path.join(tmp, ".rtreport"), "w") as fh:
                fh.write("VERSION: x\nBPS_IN: 1.5.6, BPS_OUT: 2\n"
                         "REQ_RATE []: REQ_PER_SEC: ?, TOT_REQS: 3\nEOF\n")
            vals, _ = _samples(ex.render(ex.collect(tmp)))
            self.assertEqual(vals[("ols_exporter_parse_errors", "")], 2)
            self.assertEqual(vals[("ols_up", "")], 1)
        finally:
            shutil.rmtree(tmp)


class AggregateTest(FixtureDirMixin, unittest.TestCase):
    def test_multi_process_sum(self):
        agg = ex.collect(self.tmp, max_age=30, now=self.now)
        self.assertEqual(len([p for p in agg["processes"] if p[2]]), 2)
        self.assertEqual(agg["server"]["BPS_IN"], 20)
        self.assertEqual(agg["req"]["TOT_REQS"], 124456)
        self.assertEqual(agg["vhosts"]["example.com"]["TOT_REQS"], 101000)
        ea = agg["extapps"][("LSAPI", "example.com", "lsphp82")]
        self.assertEqual(ea["INUSE_CONN"], 5)
        self.assertEqual(ea["WAITQUE_DEPTH"], 3)
        self.assertEqual(ea["CMAXCONN"], 10)  # config limit: max, not sum
        self.assertEqual(len(agg["blocked_ips"]), 3)
        self.assertEqual(agg["parse_errors"], 0)

    def test_stale_report_excluded(self):
        old = self.now - 120
        os.utime(os.path.join(self.tmp, ".rtreport.2"), (old, old))
        agg = ex.collect(self.tmp, max_age=30, now=self.now)
        self.assertEqual(agg["req"]["TOT_REQS"], 123456)
        text = ex.render(agg)
        vals, _ = _samples(text)
        self.assertEqual(vals[("ols_processes", "")], 1)
        self.assertEqual(
            vals[("ols_report_age_seconds", '{process="2"}')], 120)

    def _counters(self, text):
        vals, types = _samples(text)
        return dict((k, v) for k, v in vals.items()
                    if types.get(k[0]) == "counter")

    def test_counters_never_drop_when_worker_goes_stale(self):
        before = self._counters(
            ex.render(ex.collect(self.tmp, max_age=30, now=self.now)))
        old = self.now - 120
        os.utime(os.path.join(self.tmp, ".rtreport.2"), (old, old))
        during = self._counters(
            ex.render(ex.collect(self.tmp, max_age=30, now=self.now)))
        os.utime(os.path.join(self.tmp, ".rtreport.2"),
                 (self.now, self.now))
        after = self._counters(
            ex.render(ex.collect(self.tmp, max_age=30, now=self.now)))
        for series, value in during.items():
            self.assertGreaterEqual(value, before[series], series)
        for series, value in after.items():
            if series in during:
                self.assertGreaterEqual(value, during[series], series)
        self.assertEqual(before, after)
        # worker 2's series is absent while stale, never lower
        self.assertNotIn(("ols_requests_total", '{process="2"}'), during)
        self.assertEqual(during[("ols_requests_total", '{process="1"}')],
                         123456)

    def test_counters_never_drop_when_extapp_line_disappears(self):
        lbl1 = ('{type="LSAPI",vhost="example.com",app="lsphp82",'
                'process="1"}')
        lbl2 = ('{type="LSAPI",vhost="example.com",app="lsphp82",'
                'process="2"}')
        before = self._counters(
            ex.render(ex.collect(self.tmp, max_age=30, now=self.now)))
        self.assertEqual(before[("ols_extapp_requests_total", lbl1)], 40000)
        self.assertEqual(before[("ols_extapp_requests_total", lbl2)], 900)
        path = os.path.join(self.tmp, ".rtreport.2")
        with open(path) as fh:
            body = fh.read()
        with open(path, "w") as fh:
            fh.write("".join(l for l in body.splitlines(True)
                             if not l.startswith("EXTAPP ")))
        os.utime(path, (self.now, self.now))
        during = self._counters(
            ex.render(ex.collect(self.tmp, max_age=30, now=self.now)))
        for series, value in during.items():
            self.assertGreaterEqual(value, before[series], series)
        self.assertEqual(during[("ols_extapp_requests_total", lbl1)], 40000)
        self.assertNotIn(("ols_extapp_requests_total", lbl2), during)

    def test_empty_dir_is_down(self):
        empty = tempfile.mkdtemp(prefix="olsexp-empty-")
        try:
            vals, _ = _samples(ex.render(ex.collect(empty)))
            self.assertEqual(vals[("ols_up", "")], 0)
            self.assertNotIn(("ols_requests_total", ""), vals)
        finally:
            shutil.rmtree(empty)


class RenderTest(FixtureDirMixin, unittest.TestCase):
    def setUp(self):
        FixtureDirMixin.setUp(self)
        self.text = ex.render(ex.collect(self.tmp, max_age=30, now=self.now))
        self.vals, self.types = _samples(self.text)

    def test_types(self):
        t = self.types
        self.assertEqual(t["ols_requests_total"], "counter")
        self.assertEqual(t["ols_vhost_requests_total"], "counter")
        self.assertEqual(t["ols_cache_hits_total"], "counter")
        self.assertEqual(t["ols_extapp_requests_total"], "counter")
        self.assertEqual(t["ols_requests_per_second"], "gauge")
        self.assertEqual(t["ols_extapp_busy_connections"], "gauge")
        for name, mtype in t.items():
            if mtype == "counter":
                self.assertTrue(name.endswith("_total"), name)

    def test_values(self):
        v = self.vals
        self.assertEqual(v[("ols_up", "")], 1)
        self.assertEqual(v[("ols_processes", "")], 2)
        self.assertEqual(v[("ols_network_receive_bytes_per_second", "")],
                         20 * 1024)
        self.assertEqual(v[("ols_ssl_connections", "")], 14)
        self.assertEqual(v[("ols_requests_per_second", "")], 40)
        self.assertEqual(
            v[("ols_cache_hits_total", '{cache="public",process="1"}')], 5000)
        self.assertEqual(
            v[("ols_cache_hits_total", '{cache="public",process="2"}')], 100)
        self.assertEqual(v[("ols_requests_total", '{process="1"}')], 123456)
        self.assertEqual(v[("ols_requests_total", '{process="2"}')], 1000)
        self.assertNotIn(("ols_requests_total", ""), v)
        self.assertEqual(
            v[("ols_vhost_requests_per_second", '{vhost="example.com"}')], 35)
        self.assertEqual(
            v[("ols_vhost_cache_hits_total",
               '{vhost="example.com",cache="static",process="1"}')], 50000)
        self.assertEqual(
            v[("ols_vhost_cache_hits_total",
               '{vhost="example.com",cache="static",process="2"}')], 300)
        lbl = '{type="LSAPI",vhost="example.com",app="lsphp82"}'
        self.assertEqual(v[("ols_extapp_busy_connections", lbl)], 5)
        self.assertEqual(v[("ols_extapp_idle_connections", lbl)], 1)
        self.assertEqual(v[("ols_extapp_wait_queue_depth", lbl)], 3)
        self.assertEqual(v[("ols_blocked_ips", "")], 3)
        self.assertEqual(
            v[("ols_info", '{version="LiteSpeed Web Server/Open/1.9.4"}')], 1)

    def test_label_escaping(self):
        self.assertIn('ols_vhost_requests_total{vhost="shop \\"a\\"",'
                      'process="1"} 23456', self.text)

    def test_no_duplicate_series(self):
        series = [l.rpartition(" ")[0] for l in self.text.splitlines()
                  if l and not l.startswith("#")]
        self.assertEqual(len(series), len(set(series)))


class CardinalityTest(FixtureDirMixin, unittest.TestCase):
    def _render(self, **kw):
        agg = ex.collect(self.tmp, max_age=30, now=self.now)
        return _samples(ex.render(agg, ex.RenderOptions(**kw)))[0]

    def test_no_vhost_metrics(self):
        v = self._render(vhost_metrics=False)
        self.assertFalse([k for k in v if k[0].startswith("ols_vhost_")])
        self.assertIn(("ols_requests_per_second", ""), v)

    def test_vhost_include_exclude(self):
        v = self._render(vhost_include=r"^example\.com$")
        vh = set(k[1] for k in v if k[0] == "ols_vhost_requests_per_second")
        self.assertEqual(vh, {'{vhost="example.com"}'})
        v = self._render(vhost_exclude=r"^example\.com$")
        self.assertNotIn(
            ("ols_vhost_requests_per_second", '{vhost="example.com"}'), v)
        self.assertFalse([k for k in v if k[0].startswith("ols_extapp_")
                          and 'vhost="example.com"' in k[1]])
        # server-level extapp (vhost "") is always kept
        self.assertIn(("ols_extapp_busy_connections",
                       '{type="LSAPI",vhost="",app="lsphp"}'), v)

    def test_skip_idle_vhosts(self):
        path = os.path.join(self.tmp, ".rtreport")
        with open(path) as fh:
            body = fh.read()
        body = body.replace("BLOCKED_IP:", "REQ_RATE [idle.test]: "
                            "REQ_PROCESSING: 0, REQ_PER_SEC: 0, TOT_REQS: 0"
                            "\nBLOCKED_IP:")
        with open(path, "w") as fh:
            fh.write(body)
        os.utime(path, (self.now, self.now))
        v = self._render()
        self.assertIn(
            ("ols_vhost_requests_per_second", '{vhost="idle.test"}'), v)
        v = self._render(skip_idle_vhosts=True)
        self.assertFalse([k for k in v if 'idle.test' in k[1]])
        self.assertIn(
            ("ols_vhost_requests_per_second", '{vhost="example.com"}'), v)

    def test_bad_regex_rejected(self):
        with self.assertRaises(SystemExit):
            ex.main(["--once", "--vhost-include", "(", "--dir", self.tmp])


class HttpTest(FixtureDirMixin, unittest.TestCase):
    def tearDown(self):
        ex._Handler.auth_token = None
        FixtureDirMixin.tearDown(self)

    def _serve(self, srv):
        t = threading.Thread(target=srv.serve_forever)
        t.daemon = True
        t.start()

    def test_auth_token(self):
        ex._Handler.stat_dir = self.tmp
        ex._Handler.max_age = 3600
        ex._Handler.auth_token = "s3cret-token"
        srv = ex.make_server("127.0.0.1", 0)
        port = srv.server_address[1]
        self._serve(srv)
        url = "http://127.0.0.1:%d/metrics" % port
        try:
            for hdr in (None, "Bearer wrong", "Basic s3cret-token"):
                req = urllib.request.Request(url)
                if hdr:
                    req.add_header("Authorization", hdr)
                try:
                    urllib.request.urlopen(req, timeout=5).close()
                    self.fail("expected 401 for %r" % hdr)
                except urllib.error.HTTPError as err:
                    self.assertEqual(err.code, 401)
                    self.assertNotIn(b"example.com", err.read())
                    err.close()
            req = urllib.request.Request(url)
            req.add_header("Authorization", "Bearer s3cret-token")
            resp = urllib.request.urlopen(req, timeout=5)
            self.assertEqual(resp.status, 200)
            self.assertIn("ols_up 1", resp.read().decode("utf-8"))
            resp.close()
            # health endpoint stays open and leaks nothing
            resp = urllib.request.urlopen(
                "http://127.0.0.1:%d/healthz" % port, timeout=5)
            self.assertEqual(resp.status, 200)
            resp.close()
        finally:
            srv.shutdown()
            srv.server_close()

    def test_load_token(self):
        path = os.path.join(self.tmp, "token")
        with open(path, "w") as fh:
            fh.write("abc\n")
        os.chmod(path, 0o600)
        self.assertEqual(ex.load_token(path), "abc")
        with open(path, "w") as fh:
            fh.write("\n")
        with self.assertRaises(ValueError):
            ex.load_token(path)

    def test_ipv6_listen(self):
        if not socket.has_ipv6:
            self.skipTest("no IPv6")
        try:
            srv = ex.make_server("::1", 0)
        except (OSError, socket.gaierror) as exc:
            self.skipTest("::1 unavailable: %s" % exc)
        self.assertEqual(srv.socket.family, socket.AF_INET6)
        ex._Handler.stat_dir = self.tmp
        ex._Handler.max_age = 3600
        port = srv.server_address[1]
        self._serve(srv)
        try:
            resp = urllib.request.urlopen(
                "http://[::1]:%d/metrics" % port, timeout=5)
            self.assertIn("ols_up 1", resp.read().decode("utf-8"))
            resp.close()
        finally:
            srv.shutdown()
            srv.server_close()

    def test_metrics_endpoint(self):
        ex._Handler.stat_dir = self.tmp
        ex._Handler.max_age = 3600
        srv = ex._ThreadingServer(("127.0.0.1", 0), ex._Handler)
        port = srv.server_address[1]
        t = threading.Thread(target=srv.serve_forever)
        t.daemon = True
        t.start()
        try:
            resp = urllib.request.urlopen(
                "http://127.0.0.1:%d/metrics" % port, timeout=5)
            body = resp.read().decode("utf-8")
            self.assertEqual(resp.status, 200)
            self.assertIn("version=0.0.4",
                          resp.headers.get("Content-Type"))
            self.assertIn("ols_up 1", body)
            resp.close()
            try:
                urllib.request.urlopen(
                    "http://127.0.0.1:%d/nope" % port, timeout=5).close()
                self.fail("expected 404")
            except urllib.error.HTTPError as err:
                self.assertEqual(err.code, 404)
                err.close()
        finally:
            srv.shutdown()
            srv.server_close()


if __name__ == "__main__":
    unittest.main()
