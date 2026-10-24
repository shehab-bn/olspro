// Fixture-driven checks for src/main/apacheconf. Run: pro/tests/apacheconf/run.sh
#include "../../../src/main/apacheconf.h"
#include <cstdio>
#include <cstdlib>
#include <algorithm>

static int fails = 0;
#define CHECK(cond) do { if (!(cond)) { ++fails; \
    fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, #cond); } } while (0)

int main(int argc, char **argv)
{
    std::string dir = argc > 1 ? argv[1] : "fixtures";
    apacheconf::ParseOptions opt;
    opt.serverRoot = dir;
    apacheconf::Config cfg;
    CHECK(apacheconf::load(dir + "/httpd.conf", opt, cfg));

    // tokenizer
    auto t = apacheconf::tokenize("SetHandler \"proxy:unix:/a b|fcgi://x\" 'q r' plain");
    CHECK(t.size() == 4 && t[1] == "proxy:unix:/a b|fcgi://x" && t[2] == "q r");

    CHECK(cfg.vhosts.size() == 4 || cfg.vhosts.size() == 3);
    CHECK(cfg.vhosts.size() == 3);
    CHECK(cfg.listens.size() == 3);
    CHECK(cfg.listens[1].ip == "[::]" && cfg.listens[1].port == 80);

    const auto &h = cfg.vhosts[0];
    CHECK(h.serverName == "example.com" && h.port == 80 && h.ip == "203.0.113.9");
    CHECK(h.aliases.size() == 2);
    CHECK(h.docRoot == "/home/exuser/public_html");
    CHECK(h.user == "exuser");                         // via nested <IfModule>
    CHECK(h.hasPhp && h.php.address == "uds:///opt/cpanel/ea-php82/root/usr/var/run/php-fpm/abc123.sock");
    CHECK(h.redirects.size() == 1 && h.redirects[0].status == 301);
    CHECK(h.rewrites.size() == 1 && h.rewrites[0].conds.size() == 2);
    CHECK(h.directoryIndex.size() == 3);               // continuation + include glob
    CHECK(h.headers.size() == 1);

    const auto &s = cfg.vhosts[1];
    CHECK(s.port == 443 && s.ssl.enabled && !s.ssl.certFile.empty() && !s.ssl.chainFile.empty());
    CHECK(s.noIndexes);
    CHECK(h.noIndexes);                                 // autoindex is opt-in

    const auto &p = cfg.vhosts[2];
    CHECK(p.proxies.size() == 1 && p.proxies[0].target == "http://127.0.0.1:2082/");

    // unsupported vendor directive must be reported, not dropped silently
    bool warned = false;
    for (auto &w : cfg.warnings)
        if (w.message.find("somevendordirective") != std::string::npos) warned = true;
    CHECK(warned);

    // negated IfModule branch must NOT be visible
    CHECK(p.headers.empty());

    std::string vh = apacheconf::renderVhostConf(h, "/x");
    CHECK(vh.find("vhDomain                  example.com") != std::string::npos);
    CHECK(vh.find("extProcessor phpfpm-example.com_80") != std::string::npos);
    CHECK(vh.find("RewriteRule ^/?(.*)$ https://example.com/$1 [R=301,L]") != std::string::npos);
    std::string pv = apacheconf::renderVhostConf(p, "/x");
    CHECK(pv.find("type                    proxy") != std::string::npos);
    CHECK(pv.find("address                 127.0.0.1:2082") != std::string::npos);
    std::string sv = apacheconf::renderServerConf(cfg, "/v");
    CHECK(sv.find("listener any-443") != std::string::npos);
    CHECK(sv.find("secure                  1") != std::string::npos);
    CHECK(sv.find("setUIDMode") == std::string::npos);
    CHECK(sv.find("map                     example.com_443 example.com, www.example.com") != std::string::npos);

    printf(fails ? "%d FAILED\n" : "all apacheconf checks passed\n", fails);
    return fails ? 1 : 0;
}
