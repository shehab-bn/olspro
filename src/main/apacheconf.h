/*****************************************************************************
*    OLS PRO - native Apache httpd.conf loader.                              *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
*****************************************************************************/
#ifndef APACHECONF_H
#define APACHECONF_H

/*
 * Parses an Apache 2.4 httpd.conf tree (cPanel EA4 layout: Include globs,
 * <VirtualHost>, <IfModule>, userdata includes) into a neutral model and
 * renders that model as OpenLiteSpeed native configuration.
 *
 * Deliberately depends on the C++ standard library only, so it can be unit
 * tested and run as a standalone tool (pro/tools/apache2ols) without
 * building the server.
 *
 * Every directive that is not understood is recorded in Config::warnings
 * rather than dropped silently: "zero unsupported directives that matter"
 * is a measurable acceptance criterion for cPanel parity.
 */

#include <map>
#include <string>
#include <vector>

namespace apacheconf
{

struct Node
{
    std::string name;               // lower-cased directive / section name
    std::vector<std::string> args;
    std::vector<Node> children;     // only for sections
    bool isSection = false;
    std::string file;
    int line = 0;
};

struct ParseOptions
{
    std::string serverRoot = "/etc/apache2";
    int maxDepth = 32;
};

struct Warning
{
    std::string file;
    int line;
    std::string message;
};

struct Rewrite
{
    std::vector<std::string> conds;   // raw "RewriteCond ..." argument text
    std::string rule;                 // raw "RewriteRule ..." argument text
};

struct PhpHandler
{
    std::string kind;       // "fcgi"
    std::string address;    // uds://path or 127.0.0.1:port
};

struct SslInfo
{
    bool enabled = false;
    std::string certFile;
    std::string keyFile;
    std::string chainFile;
    std::string caFile;
};

struct VHost
{
    std::string addr;                  // as written: "203.0.113.9:443" or "*:80"
    std::string ip;                    // "*" or an address
    int port = 80;
    std::string serverName;
    std::vector<std::string> aliases;
    std::string docRoot;
    std::string user, group;           // SuexecUserGroup
    std::string serverAdmin;
    std::string errorLog;
    std::string accessLog;
    std::vector<std::string> directoryIndex;
    SslInfo ssl;
    bool hasPhp = false;
    PhpHandler php;
    std::vector<Rewrite> rewrites;
    bool rewriteEnabled = false;
    // Redirect / RedirectMatch: status, from, to
    struct Redir { int status; std::string from; std::string to; bool regex; };
    std::vector<Redir> redirects;
    // ProxyPass path target (cPanel service subdomains)
    struct Proxy { std::string path; std::string target; bool regex; };
    std::vector<Proxy> proxies;
    // Header set|always set|unset ...
    std::vector<std::vector<std::string>> headers;
    bool noIndexes = true;      // autoindex is opt-in (Options +Indexes)
    std::string file;
    int line = 0;
};

struct Listen
{
    std::string ip;   // "*" or address
    int port;
};

struct Config
{
    std::string serverRoot;
    std::string serverName;
    std::vector<Listen> listens;
    std::vector<VHost> vhosts;
    std::vector<Warning> warnings;
    int filesRead = 0;
};

/* Parse path (and everything it Includes) into a directive tree. Returns
 * false only if the top-level file cannot be read. */
bool parseTree(const std::string &path, const ParseOptions &opt, Node &root,
               std::vector<Warning> &warnings, int *filesRead = nullptr);

/* Walk the tree and build the model. */
void buildConfig(const Node &root, Config &cfg);

/* Convenience: parseTree + buildConfig. */
bool load(const std::string &path, const ParseOptions &opt, Config &cfg);

/* Render the OLS vhost config (vhconf.conf body) for one vhost. */
std::string renderVhostConf(const VHost &v, const std::string &vhRoot);

/* Render the server-level fragment: listeners + virtualhost blocks with maps.
 * vhostDir is where per-vhost vhconf.conf files live (<vhostDir>/<name>/). */
std::string renderServerConf(const Config &cfg, const std::string &vhostDir);

/* Stable OLS virtual host name for a vhost (domain + port, filesystem safe). */
std::string vhostId(const VHost &v);

/* Split "a,b" style helpers exposed for tests. */
std::vector<std::string> tokenize(const std::string &line);

}  // namespace apacheconf

#endif  // APACHECONF_H
