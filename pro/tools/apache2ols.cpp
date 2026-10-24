// apache2ols: standalone driver for src/main/apacheconf.
//   apache2ols [--root /etc/apache2] [--out DIR] [--warnings] httpd.conf
// Without --out prints the server fragment to stdout; with --out writes
// DIR/olspro_apache.conf and DIR/vhosts/<id>/vhconf.conf.
#include "../../src/main/apacheconf.h"
#include <sys/stat.h>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <iostream>

static void mkdirs(const std::string &p)
{
    for (size_t i = 1; i <= p.size(); ++i)
        if (i == p.size() || p[i] == '/')
            mkdir(p.substr(0, i).c_str(), 0755);
}

int main(int argc, char **argv)
{
    apacheconf::ParseOptions opt;
    std::string out, file;
    bool warnings = false;
    for (int i = 1; i < argc; ++i)
    {
        if (!strcmp(argv[i], "--root") && i + 1 < argc)
            opt.serverRoot = argv[++i];
        else if (!strcmp(argv[i], "--out") && i + 1 < argc)
            out = argv[++i];
        else if (!strcmp(argv[i], "--warnings"))
            warnings = true;
        else
            file = argv[i];
    }
    if (file.empty())
    {
        fprintf(stderr, "usage: apache2ols [--root DIR] [--out DIR] [--warnings] httpd.conf\n");
        return 2;
    }
    apacheconf::Config cfg;
    if (!apacheconf::load(file, opt, cfg))
    {
        fprintf(stderr, "cannot read %s\n", file.c_str());
        return 1;
    }
    fprintf(stderr, "%zu vhosts, %zu listeners, %d files, %zu warnings\n",
            cfg.vhosts.size(), cfg.listens.size(), cfg.filesRead, cfg.warnings.size());
    if (warnings)
        for (auto &w : cfg.warnings)
            fprintf(stderr, "WARN %s:%d %s\n", w.file.c_str(), w.line, w.message.c_str());
    std::string vdir = out.empty() ? "vhosts" : out + "/vhosts";
    std::string server = apacheconf::renderServerConf(cfg, vdir);
    if (out.empty())
    {
        std::cout << server;
        return 0;
    }
    mkdirs(out);
    std::ofstream(out + "/olspro_apache.conf") << server;
    for (auto &v : cfg.vhosts)
    {
        std::string d = vdir + "/" + apacheconf::vhostId(v);
        mkdirs(d);
        std::ofstream(d + "/vhconf.conf") << apacheconf::renderVhostConf(v, d);
    }
    return 0;
}
