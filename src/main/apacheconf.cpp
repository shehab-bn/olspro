/*****************************************************************************
*    OLS PRO - native Apache httpd.conf loader.                              *
*    GPLv3, see GPL.txt                                                      *
*****************************************************************************/
#include "apacheconf.h"

#include <glob.h>
#include <sys/stat.h>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <fstream>
#include <set>
#include <sstream>

namespace apacheconf
{

static std::string lower(std::string s)
{
    for (auto &c : s)
        c = (char)std::tolower((unsigned char)c);
    return s;
}

static std::string trim(const std::string &s)
{
    size_t b = 0, e = s.size();
    while (b < e && std::isspace((unsigned char)s[b]))
        ++b;
    while (e > b && std::isspace((unsigned char)s[e - 1]))
        --e;
    return s.substr(b, e - b);
}

std::vector<std::string> tokenize(const std::string &line)
{
    std::vector<std::string> out;
    std::string cur;
    bool have = false;
    char quote = 0;
    for (size_t i = 0; i < line.size(); ++i)
    {
        char c = line[i];
        if (quote)
        {
            if (c == '\\' && i + 1 < line.size()
                && (line[i + 1] == quote || line[i + 1] == '\\'))
                cur += line[++i];
            else if (c == quote)
                quote = 0;
            else
                cur += c;
        }
        else if (c == '"' || c == '\'')
        {
            quote = c;
            have = true;
        }
        else if (std::isspace((unsigned char)c))
        {
            if (have)
            {
                out.push_back(cur);
                cur.clear();
                have = false;
            }
        }
        else
        {
            cur += c;
            have = true;
        }
    }
    if (have)
        out.push_back(cur);
    return out;
}

static bool isDir(const std::string &p)
{
    struct stat st;
    return stat(p.c_str(), &st) == 0 && S_ISDIR(st.st_mode);
}

static std::string absPath(const std::string &p, const std::string &root)
{
    if (!p.empty() && p[0] == '/')
        return p;
    return root + "/" + p;
}

struct Parser
{
    const ParseOptions &opt;
    std::vector<Warning> &warn;
    std::map<std::string, std::string> defines;
    std::set<std::string> stack;     // include cycle guard
    int filesRead;

    Parser(const ParseOptions &o, std::vector<Warning> &w)
        : opt(o), warn(w), filesRead(0) {}

    std::string expand(const std::string &s) const
    {
        std::string out;
        for (size_t i = 0; i < s.size(); ++i)
        {
            if (s[i] == '$' && i + 1 < s.size() && s[i + 1] == '{')
            {
                size_t e = s.find('}', i);
                if (e != std::string::npos)
                {
                    auto it = defines.find(s.substr(i + 2, e - i - 2));
                    if (it != defines.end())
                    {
                        out += it->second;
                        i = e;
                        continue;
                    }
                }
            }
            out += s[i];
        }
        return out;
    }

    void include(const std::string &pattern, Node &parent, int depth,
                 bool optional, const std::string &file, int line)
    {
        std::string pat = absPath(expand(pattern), opt.serverRoot);
        std::vector<std::string> files;
        if (isDir(pat))
        {
            // Apache includes every file in the directory (recursively).
            glob_t g;
            if (glob((pat + "/*").c_str(), 0, nullptr, &g) == 0)
            {
                for (size_t i = 0; i < g.gl_pathc; ++i)
                {
                    if (isDir(g.gl_pathv[i]))
                        include(g.gl_pathv[i], parent, depth, true, file, line);
                    else
                        files.push_back(g.gl_pathv[i]);
                }
            }
            globfree(&g);
        }
        else if (pat.find_first_of("*?[") != std::string::npos)
        {
            glob_t g;
            if (glob(pat.c_str(), 0, nullptr, &g) == 0)
                for (size_t i = 0; i < g.gl_pathc; ++i)
                    files.push_back(g.gl_pathv[i]);
            globfree(&g);
        }
        else
            files.push_back(pat);

        if (files.empty() && !optional && pat.find_first_of("*?[") == std::string::npos)
            warn.push_back({file, line, "Include target not found: " + pat});
        for (auto &f : files)
            parseFile(f, parent, depth + 1, optional);
    }

    bool parseFile(const std::string &path, Node &parent, int depth, bool optional)
    {
        if (depth > opt.maxDepth)
        {
            warn.push_back({path, 0, "Include depth limit reached"});
            return false;
        }
        if (stack.count(path))
        {
            warn.push_back({path, 0, "Include cycle ignored"});
            return false;
        }
        std::ifstream in(path);
        if (!in)
        {
            if (!optional)
                warn.push_back({path, 0, "cannot read file"});
            return false;
        }
        ++filesRead;
        stack.insert(path);

        std::vector<Node *> open;       // section stack; open.back() receives children
        open.push_back(&parent);
        std::string line, logical;
        int lineNo = 0, startLine = 0;
        while (std::getline(in, line))
        {
            ++lineNo;
            if (logical.empty())
                startLine = lineNo;
            std::string t = line;
            if (!t.empty() && t.back() == '\r')
                t.pop_back();
            // continuation: odd number of trailing backslashes
            size_t bs = 0;
            while (bs < t.size() && t[t.size() - 1 - bs] == '\\')
                ++bs;
            if (bs % 2 == 1)
            {
                t.pop_back();
                logical += t + " ";
                continue;
            }
            logical += t;
            std::string s = trim(logical);
            logical.clear();
            if (s.empty() || s[0] == '#')
                continue;

            if (s[0] == '<')
            {
                if (s.size() > 1 && s[1] == '/')
                {
                    if (open.size() > 1)
                        open.pop_back();
                    else
                        warn.push_back({path, startLine, "unmatched closing section"});
                    continue;
                }
                size_t gt = s.rfind('>');
                std::string inner = s.substr(1, (gt == std::string::npos ? s.size() : gt) - 1);
                auto tok = tokenize(expand(inner));
                if (tok.empty())
                    continue;
                Node sec;
                sec.isSection = true;
                sec.name = lower(tok[0]);
                sec.args.assign(tok.begin() + 1, tok.end());
                sec.file = path;
                sec.line = startLine;
                open.back()->children.push_back(std::move(sec));
                open.push_back(&open.back()->children.back());
                continue;
            }

            auto tok = tokenize(expand(s));
            if (tok.empty())
                continue;
            std::string name = lower(tok[0]);
            std::vector<std::string> args(tok.begin() + 1, tok.end());

            if (name == "include" || name == "includeoptional")
            {
                if (!args.empty())
                    include(args[0], *open.back(), depth, name == "includeoptional",
                            path, startLine);
                continue;
            }
            if (name == "define" && args.size() >= 1)
            {
                defines[args[0]] = args.size() > 1 ? args[1] : "1";
                continue;
            }
            Node d;
            d.name = name;
            d.args = std::move(args);
            d.file = path;
            d.line = startLine;
            open.back()->children.push_back(std::move(d));
        }
        stack.erase(path);
        return true;
    }
};

bool parseTree(const std::string &path, const ParseOptions &opt, Node &root,
               std::vector<Warning> &warnings, int *filesRead)
{
    Parser p(opt, warnings);
    root.isSection = true;
    root.name = "root";
    bool ok = p.parseFile(path, root, 0, false);
    if (filesRead)
        *filesRead = p.filesRead;
    return ok;
}

/* ------------------------------------------------------------------------- */

static void splitAddr(const std::string &a, std::string &ip, int &port, int defPort)
{
    ip = a;
    port = defPort;
    auto isNum = [](const std::string &x)
    { return !x.empty() && std::all_of(x.begin(), x.end(), ::isdigit); };
    if (isNum(a))
    {
        ip = "*";
        port = std::atoi(a.c_str());
        return;
    }
    size_t portAt = std::string::npos;
    if (!a.empty() && a[0] == '[')                   // [v6]:port
    {
        size_t e = a.find(']');
        if (e != std::string::npos)
        {
            ip = a.substr(0, e + 1);
            if (e + 1 < a.size() && a[e + 1] == ':')
                portAt = e + 2;
        }
    }
    else
    {
        size_t c = a.rfind(':');
        if (c != std::string::npos)
        {
            ip = a.substr(0, c);
            portAt = c + 1;
        }
    }
    if (portAt != std::string::npos && isNum(a.substr(portAt)))
        port = std::atoi(a.c_str() + portAt);
    if (ip.empty())
        ip = "*";
}

static bool isOn(const std::string &s)
{
    std::string l = lower(s);
    return l == "on" || l == "1" || l == "true";
}

static bool moduleCondition(const Node &n)
{
    // <IfModule mod_x.c> / <IfModule !mod_x.c>: treat positive as satisfied
    // (cPanel EA4 ships the modules it references) and negated as unsatisfied.
    if (n.args.empty())
        return true;
    return n.args[0][0] != '!';
}

// Directives we model; anything else inside a vhost is reported once.
static const std::set<std::string> &knownVhostDirectives()
{
    static const std::set<std::string> k = {
        "servername", "serveralias", "documentroot", "suexecusergroup",
        "serveradmin", "errorlog", "customlog", "transferlog", "directoryindex",
        "sslengine", "sslcertificatefile", "sslcertificatekeyfile",
        "sslcertificatechainfile", "sslcacertificatefile",
        "rewriteengine", "rewritecond", "rewriterule", "rewritebase",
        "redirect", "redirectmatch", "redirectpermanent", "redirecttemp",
        "proxypass", "proxypassmatch", "proxypassreverse", "header",
        "sethandler", "options", "scriptalias", "scriptaliasmatch", "alias",
        "loglevel", "usecanonicalname", "serverpath", "cpanelemailstats",
        "userdir", "phpini", "ifmodule", "setenvif", "setenv", "php_value",
        "php_flag", "php_admin_value", "php_admin_flag", "addtype",
        "adddefaultcharset", "allowoverride", "require", "order", "allow",
        "deny", "files", "filesmatch", "directory", "directorymatch",
        "location", "locationmatch", "ifversion", "ifdefine", "ifdirective",
        "sslprotocol", "sslciphersuite", "sslhonorcipherorder",
        "sslusestapling", "sslopensslconfcmd", "keepalive", "timeout",
        "serverroot", "customlog", "errordocument", "expiresactive",
        "expiresbytype", "expiresdefault", "addhandler", "addoutputfilter",
        "setoutputfilter", "browsermatch", "limitrequestbody",
        "proxypreservehost", "sslproxyengine", "suphp_usergroup",
        "fcgidwrapper", "loadmodule", "namevirtualhost", "listen",
    };
    return k;
}

struct Builder
{
    Config &cfg;
    explicit Builder(Config &c) : cfg(c) {}

    void warn(const Node &n, const std::string &m)
    {
        cfg.warnings.push_back({n.file, n.line, m});
    }

    // Extract a PHP-FPM / fcgi target from SetHandler "proxy:unix:/sock|fcgi://x"
    // or "proxy:fcgi://127.0.0.1:9000".
    static bool phpFromHandler(const std::string &h, PhpHandler &out)
    {
        const std::string unix_ = "proxy:unix:";
        if (h.compare(0, unix_.size(), unix_) == 0)
        {
            std::string rest = h.substr(unix_.size());
            size_t bar = rest.find('|');
            out.kind = "fcgi";
            out.address = "uds://" + (bar == std::string::npos ? rest : rest.substr(0, bar));
            return true;
        }
        const std::string fcgi = "proxy:fcgi://";
        if (h.compare(0, fcgi.size(), fcgi) == 0)
        {
            std::string rest = h.substr(fcgi.size());
            size_t sl = rest.find('/');
            out.kind = "fcgi";
            out.address = sl == std::string::npos ? rest : rest.substr(0, sl);
            return true;
        }
        return false;
    }

    void walkVhost(const Node &n, VHost &v, bool inPhpMatch)
    {
        for (const Node &c : n.children)
        {
            if (c.isSection)
            {
                if (c.name == "ifmodule")
                {
                    if (moduleCondition(c))
                        walkVhost(c, v, inPhpMatch);
                }
                else if (c.name == "ifversion" || c.name == "ifdefine"
                         || c.name == "ifdirective")
                    walkVhost(c, v, inPhpMatch);
                else if (c.name == "filesmatch" || c.name == "files")
                    walkVhost(c, v, true);
                else if (c.name == "directory" || c.name == "directorymatch"
                         || c.name == "location" || c.name == "locationmatch")
                {
                    // Per-directory policy is carried by .htaccess/contexts in
                    // OLS; only harvest handler + Options info from them.
                    walkVhost(c, v, inPhpMatch);
                }
                else
                    warn(c, "unsupported section <" + c.name + ">");
                continue;
            }
            const std::string &d = c.name;
            const auto &a = c.args;
            if (d == "servername" && !a.empty())
            {
                if (v.serverName.empty())
                    v.serverName = a[0];
            }
            else if (d == "serveralias")
                v.aliases.insert(v.aliases.end(), a.begin(), a.end());
            else if (d == "documentroot" && !a.empty())
            {
                if (v.docRoot.empty())
                    v.docRoot = a[0];
            }
            else if (d == "suexecusergroup" && a.size() >= 2)
            {
                v.user = a[0];
                v.group = a[1];
            }
            else if (d == "serveradmin" && !a.empty())
                v.serverAdmin = a[0];
            else if (d == "errorlog" && !a.empty())
                v.errorLog = a[0];
            else if ((d == "customlog" || d == "transferlog") && !a.empty())
            {
                if (v.accessLog.empty())
                    v.accessLog = a[0];
            }
            else if (d == "directoryindex")
                v.directoryIndex.insert(v.directoryIndex.end(), a.begin(), a.end());
            else if (d == "sslengine" && !a.empty())
                v.ssl.enabled = isOn(a[0]);
            else if (d == "sslcertificatefile" && !a.empty())
                v.ssl.certFile = a[0];
            else if (d == "sslcertificatekeyfile" && !a.empty())
                v.ssl.keyFile = a[0];
            else if (d == "sslcertificatechainfile" && !a.empty())
                v.ssl.chainFile = a[0];
            else if (d == "sslcacertificatefile" && !a.empty())
                v.ssl.caFile = a[0];
            else if (d == "rewriteengine" && !a.empty())
                v.rewriteEnabled = isOn(a[0]);
            else if (d == "rewritecond")
            {
                if (v.rewrites.empty() || !v.rewrites.back().rule.empty())
                    v.rewrites.push_back(Rewrite());
                std::string joined;
                for (auto &x : a)
                    joined += (joined.empty() ? "" : " ") + x;
                v.rewrites.back().conds.push_back(joined);
            }
            else if (d == "rewriterule")
            {
                if (v.rewrites.empty() || !v.rewrites.back().rule.empty())
                    v.rewrites.push_back(Rewrite());
                std::string joined;
                for (auto &x : a)
                    joined += (joined.empty() ? "" : " ") + x;
                v.rewrites.back().rule = joined;
            }
            else if ((d == "redirect" || d == "redirectmatch") && a.size() >= 2)
            {
                // Redirect [status] path url
                int status = 302;
                size_t i = 0;
                std::string first = lower(a[0]);
                if (first == "permanent")
                    status = 301, ++i;
                else if (first == "temp")
                    status = 302, ++i;
                else if (first == "seeother")
                    status = 303, ++i;
                else if (first == "gone")
                    status = 410, ++i;
                else if (!first.empty() && std::all_of(first.begin(), first.end(), ::isdigit))
                    status = std::atoi(first.c_str()), ++i;
                if (a.size() >= i + 2)
                    v.redirects.push_back({status, a[i], a[i + 1], d == "redirectmatch"});
                else if (status == 410 && a.size() == i + 1)
                    v.redirects.push_back({410, a[i], "", d == "redirectmatch"});
            }
            else if (d == "redirectpermanent" && a.size() >= 2)
                v.redirects.push_back({301, a[0], a[1], false});
            else if (d == "redirecttemp" && a.size() >= 2)
                v.redirects.push_back({302, a[0], a[1], false});
            else if ((d == "proxypass" || d == "proxypassmatch") && a.size() >= 2)
                v.proxies.push_back({a[0], a[1], d == "proxypassmatch"});
            else if (d == "header")
                v.headers.push_back(a);
            else if (d == "sethandler" && !a.empty())
            {
                PhpHandler p;
                if (phpFromHandler(a[0], p))
                {
                    v.hasPhp = true;
                    v.php = p;
                }
                else if (!inPhpMatch || lower(a[0]) != "application/x-httpd-php")
                    warn(c, "SetHandler not mapped: " + a[0]);
            }
            else if (d == "options")
            {
                for (auto &o : a)
                {
                    std::string l = lower(o);
                    if (l == "indexes" || l == "+indexes")
                        v.noIndexes = false;        // field means "autoindex allowed" when false
                    else if (l == "-indexes")
                        v.noIndexes = true;
                }
            }
            else if (!knownVhostDirectives().count(d))
                warn(c, "unsupported directive in VirtualHost: " + c.name);
        }
    }

    void walkGlobal(const Node &n)
    {
        for (const Node &c : n.children)
        {
            if (c.isSection)
            {
                if (c.name == "virtualhost")
                {
                    VHost v;
                    v.file = c.file;
                    v.line = c.line;
                    v.addr = c.args.empty() ? "*:80" : c.args[0];
                    splitAddr(v.addr, v.ip, v.port, 80);
                    walkVhost(c, v, false);
                    if (v.serverName.empty())
                        v.serverName = v.ip == "*" ? "_default_" : v.ip;
                    cfg.vhosts.push_back(std::move(v));
                }
                else if (c.name == "ifmodule")
                {
                    if (moduleCondition(c))
                        walkGlobal(c);
                }
                else if (c.name == "ifversion" || c.name == "ifdefine")
                    walkGlobal(c);
                continue;
            }
            if (c.name == "listen" && !c.args.empty())
            {
                Listen l;
                splitAddr(c.args[0], l.ip, l.port, 80);
                cfg.listens.push_back(l);
            }
            else if (c.name == "servername" && !c.args.empty() && cfg.serverName.empty())
                cfg.serverName = c.args[0];
            else if (c.name == "serverroot" && !c.args.empty())
                cfg.serverRoot = c.args[0];
        }
    }
};

void buildConfig(const Node &root, Config &cfg)
{
    Builder b(cfg);
    b.walkGlobal(root);
}

bool load(const std::string &path, const ParseOptions &opt, Config &cfg)
{
    Node root;
    int n = 0;
    bool ok = parseTree(path, opt, root, cfg.warnings, &n);
    cfg.filesRead = n;
    if (cfg.serverRoot.empty())
        cfg.serverRoot = opt.serverRoot;
    if (ok)
        buildConfig(root, cfg);
    return ok;
}

/* ------------------------------ rendering -------------------------------- */

std::string vhostId(const VHost &v)
{
    std::string id = v.serverName + "_" + std::to_string(v.port);
    for (auto &c : id)
        if (!(std::isalnum((unsigned char)c) || c == '.' || c == '-' || c == '_'))
            c = '_';
    return id;
}

static std::string join(const std::vector<std::string> &v, const char *sep)
{
    std::string o;
    for (size_t i = 0; i < v.size(); ++i)
        o += (i ? sep : "") + v[i];
    return o;
}

// Apache -> OLS rewrite flag translation. OLS has no "return arbitrary 4xx"
// flag: R=4xx / G are expressed as F (403); documented in ROADMAP G3.
static std::string translateRewriteRule(const std::string &raw)
{
    auto t = tokenize(raw);
    if (t.size() < 2)
        return "RewriteRule " + raw;
    std::string flags = t.size() > 2 ? t[2] : "";
    if (!flags.empty() && flags.front() == '[' && flags.back() == ']')
    {
        std::string f = flags.substr(1, flags.size() - 2);
        std::vector<std::string> keep;
        bool forbid = false;
        std::stringstream ss(f);
        std::string x;
        while (std::getline(ss, x, ','))
        {
            std::string l = lower(trim(x));
            if (l == "g" || l == "gone" || l == "forbidden" || l == "f"
                || (l.size() == 5 && l.compare(0, 2, "r=") == 0 && l[2] == '4'))
                forbid = true;
            else if (!l.empty())
                keep.push_back(trim(x));
        }
        if (forbid)
            keep.insert(keep.begin(), "F");
        if (std::find(keep.begin(), keep.end(), "L") == keep.end() && forbid)
            keep.push_back("L");
        flags = "[" + join(keep, ",") + "]";
    }
    return "RewriteRule " + t[0] + " " + t[1] + (flags.empty() ? "" : " " + flags);
}

std::string renderVhostConf(const VHost &v, const std::string &vhRoot)
{
    std::ostringstream o;
    o << "# generated by OLS PRO apacheconf from " << v.file << ":" << v.line << "\n";
    o << "docRoot                   " << (v.docRoot.empty() ? "$VH_ROOT/html" : v.docRoot) << "/\n";
    o << "vhDomain                  " << v.serverName << "\n";
    if (!v.aliases.empty())
        o << "vhAliases                 " << join(v.aliases, ", ") << "\n";
    o << "adminEmails               " << (v.serverAdmin.empty() ? "root@localhost" : v.serverAdmin) << "\n";
    o << "enableGzip                1\n\n";

    o << "index  {\n";
    o << "  indexFiles              "
      << (v.directoryIndex.empty() ? "index.php, index.html" : join(v.directoryIndex, ", ")) << "\n";
    o << "  autoIndex               " << (v.noIndexes ? 0 : 1) << "\n}\n\n";

    if (v.hasPhp)
    {
        std::string h = "phpfpm-" + vhostId(v);
        o << "scriptHandler  {\n  add                     fcgi:" << h << " php\n}\n\n";
        o << "extProcessor " << h << " {\n";
        o << "  type                    fcgi\n";
        o << "  address                 " << v.php.address << "\n";
        o << "  maxConns                20\n";
        o << "  initTimeout             60\n  retryTimeout            0\n";
        o << "  persistConn             0\n  respBuffer              0\n";
        o << "  autoStart               0\n  backlog                 100\n";
        o << "  extMaxIdleTime          300\n  priority                0\n}\n\n";
    }

    o << "context / {\n  location                $DOC_ROOT/\n  allowBrowse             1\n";
    o << "  rewrite  {\n    enable                1\n    autoLoadHtaccess      1\n  }\n}\n\n";

    // ACME / cPanel DCV must stay reachable as plain static files (ROADMAP G2).
    o << "context /.well-known/ {\n  location                $DOC_ROOT/.well-known/\n  allowBrowse             1\n}\n\n";

    // ProxyPass -> OLS proxy extApp + context (cPanel service subdomains, G2).
    int pn = 0;
    for (auto &p : v.proxies)
    {
        bool http = p.target.compare(0, 7, "http://") == 0 || p.target.compare(0, 8, "https://") == 0;
        if (p.regex || p.path.empty() || !http)
        {
            o << "# UNSUPPORTED ProxyPass" << (p.regex ? "Match " : " ") << p.path << " " << p.target << "\n";
            continue;
        }
        std::string name = "proxy" + std::to_string(++pn);
        std::string addr = p.target;                 // OLS wants host:port (+ scheme for https)
        bool https = addr.compare(0, 8, "https://") == 0;
        addr = addr.substr(https ? 8 : 7);
        size_t sl = addr.find('/');
        if (sl != std::string::npos)
            addr = addr.substr(0, sl);
        if (https)
            addr = "https://" + addr;
        std::string path = p.path;
        if (path.back() != '/')
            path += "/";
        o << "extProcessor " << name << " {\n  type                    proxy\n  address                 " << addr
          << "\n  maxConns                100\n  pcKeepAliveTimeout      60\n  initTimeout             60\n"
             "  retryTimeout            0\n  respBuffer              0\n}\n\n";
        o << "context " << path << " {\n  type                    proxy\n  handler                 " << name
          << "\n  addDefaultCharset       off\n}\n\n";
    }

    bool needRewrite = !v.rewrites.empty() || !v.redirects.empty();
    if (needRewrite)
    {
        o << "rewrite  {\n  enable                  1\n  autoLoadHtaccess        1\n  rules                   <<<END_rules\n";
        for (auto &r : v.redirects)
        {
            if (r.regex)
                o << "RewriteRule " << r.from << " " << (r.to.empty() ? "-" : r.to)
                  << " [R=" << r.status << ",L]\n";
            else
            {
                std::string to = r.to;
                if (to.size() > 1 && to.back() == '/' && !r.from.empty() && r.from.back() != '/')
                    to.pop_back();                 // Redirect appends the remainder (which starts with '/')
                o << "RewriteRule ^" << r.from << "(.*)$ " << (to.empty() ? "-" : to)
                  << "$1 [R=" << r.status << ",L]\n";
            }
        }
        for (auto &r : v.rewrites)
        {
            for (auto &c : r.conds)
                o << "RewriteCond " << c << "\n";
            if (!r.rule.empty())
                o << translateRewriteRule(r.rule) << "\n";
        }
        o << "END_rules\n}\n\n";
    }

    if (!v.errorLog.empty())
        o << "errorlog " << v.errorLog << " {\n  useServer               0\n  logLevel                WARN\n  rollingSize             10M\n}\n\n";
    if (!v.accessLog.empty())
        o << "accessLog " << v.accessLog << " {\n  useServer               0\n  rollingSize             10M\n  keepDays                30\n}\n\n";

    if (v.ssl.enabled && !v.ssl.certFile.empty() && !v.ssl.keyFile.empty())
    {
        o << "vhssl  {\n  keyFile                 " << v.ssl.keyFile << "\n  certFile                "
          << v.ssl.certFile << "\n";
        if (!v.ssl.chainFile.empty() || !v.ssl.caFile.empty())
            o << "  CACertFile              "
              << (v.ssl.chainFile.empty() ? v.ssl.caFile : v.ssl.chainFile) << "\n";
        o << "  certChain               1\n}\n";
    }
    (void)vhRoot;
    return o.str();
}

static bool isWildcardIp(const std::string &ip)
{
    return ip == "*" || ip == "0.0.0.0" || ip == "[::]" || ip == "_default_" || ip.empty();
}

std::string renderServerConf(const Config &cfg, const std::string &vhostDir)
{
    // Apache: Listen opens sockets, <VirtualHost ip:port> picks by name/address.
    // OLS: one listener per socket, vhosts mapped by domain. So: one listener
    // per port for wildcard Listens (dual-stack if any v6 wildcard on it) and
    // one per specific-address Listen. IP-based vhosts fall back to the port's
    // wildcard listener, which is correct for name+SNI hosting.
    struct L
    {
        std::string ip;      // "*" for wildcard
        int port;
        bool v6 = false;
        bool secure = false;
        std::string key, cert;
        std::vector<const VHost *> maps;
    };
    std::map<std::string, L> ls;
    auto listenerFor = [&](const std::string &ip, int port, bool v6) -> L &
    {
        std::string wip = isWildcardIp(ip) ? "*" : ip;
        std::string k = wip + ":" + std::to_string(port);
        L &l = ls[k];
        l.ip = wip;
        l.port = port;
        if (v6 && wip == "*")
            l.v6 = true;
        return l;
    };
    for (const Listen &x : cfg.listens)
        listenerFor(x.ip, x.port, x.ip == "[::]");
    for (const VHost &v : cfg.vhosts)
    {
        std::string wip = isWildcardIp(v.ip) ? "*" : v.ip;
        if (!ls.count(wip + ":" + std::to_string(v.port)) && !ls.count("*:" + std::to_string(v.port)))
            listenerFor(wip, v.port, false);
    }

    std::ostringstream o;
    o << "# generated by OLS PRO apacheconf (" << cfg.vhosts.size() << " vhosts, "
      << cfg.filesRead << " files read)\n\n";

    std::set<std::string> seen;
    for (const VHost &v : cfg.vhosts)
    {
        std::string id = vhostId(v);
        if (!seen.insert(id).second)
            continue;
        o << "virtualhost " << id << " {\n";
        o << "  vhRoot                  " << (v.docRoot.empty() ? vhostDir + "/" + id : v.docRoot) << "\n";
        o << "  configFile              " << vhostDir << "/" << id << "/vhconf.conf\n";
        o << "  allowSymbolLink         1\n  enableScript            1\n  restrained              0\n";
        // No setUIDMode/suEXEC: stock OLS has no lscgid; PHP runs in the
        // account's own FPM pool (chpro crash-loop 2026-10-24).
        o << "}\n\n";
        // choose listener: exact ip:port, else the port's wildcard
        std::string wip = isWildcardIp(v.ip) ? "*" : v.ip;
        auto it = ls.find(wip + ":" + std::to_string(v.port));
        if (it == ls.end())
            it = ls.find("*:" + std::to_string(v.port));
        if (it == ls.end())
            continue;
        it->second.maps.push_back(&v);
        if (wip == "*" || it->second.ip != "*")
            ;  // fallthrough
        if (v.ssl.enabled)
        {
            it->second.secure = true;
            if (it->second.cert.empty())
            {
                it->second.cert = v.ssl.certFile;
                it->second.key = v.ssl.keyFile;
            }
        }
        // a wildcard vhost also serves every other listener on that port
        if (wip == "*")
            for (auto &kv : ls)
                if (&kv.second != &it->second && kv.second.port == v.port)
                {
                    kv.second.maps.push_back(&v);
                    if (v.ssl.enabled)
                    {
                        kv.second.secure = true;
                        if (kv.second.cert.empty())
                        {
                            kv.second.cert = v.ssl.certFile;
                            kv.second.key = v.ssl.keyFile;
                        }
                    }
                }
    }

    for (auto &kv : ls)
    {
        const L &l = kv.second;
        o << "listener " << (l.ip == "*" ? "any" : l.ip) << "-" << l.port << " {\n";
        o << "  address                 " << (l.ip == "*" ? (l.v6 ? "[ANY]" : "*") : l.ip) << ":" << l.port << "\n";
        o << "  secure                  " << (l.secure ? 1 : 0) << "\n";
        if (l.secure && !l.cert.empty())
            o << "  keyFile                 " << l.key << "\n  certFile                " << l.cert << "\n";
        std::set<std::string> mapped;
        for (const VHost *v : l.maps)
        {
            std::string id = vhostId(*v);
            if (!mapped.insert(id).second)
                continue;
            std::string doms = v->serverName;
            for (auto &a : v->aliases)
                doms += ", " + a;
            o << "  map                     " << id << " " << doms << "\n";
        }
        o << "}\n\n";
    }
    return o.str();
}

}  // namespace apacheconf
