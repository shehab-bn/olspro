/*****************************************************************************
*    OLS PRO - native Apache httpd.conf loader, startup integration.         *
*                                                                            *
*    This program is free software: you can redistribute it and/or modify    *
*    it under the terms of the GNU General Public License as published by    *
*    the Free Software Foundation, either version 3 of the License, or       *
*    (at your option) any later version.                                     *
*****************************************************************************/
#include "apacheconf_loader.h"
#include "apacheconf.h"

#include <log4cxx/logger.h>

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

#include <exception>
#include <set>
#include <string>
#include <vector>

namespace apacheconf
{

static const char *GEN_DIR_NAME    = "apache-generated";   // <serverRoot>/...
static const char *SERVER_FRAGMENT = "olspro_apache.conf";
static const char *LOG_FILE        = "olspro_apache.log";
static const char *GEN_PREFIX      = "gen-";
static const char *HASH_TAG        = "# olspro-apacheconf hash=";
// Stands in for the generation directory while rendering, so the content
// hash does not depend on which gen-* directory the files end up in.
static const char *PLACEHOLDER     = "\x01OLSPRO_GEN\x01";

/* Refuse to replace a fragment when the vhost count drops by more than this
 * (and by more than MAX_DROP_ABS), unless OLSPRO_APACHE_FORCE=1. */
static const int MAX_DROP_PCT = 20;
static const int MAX_DROP_ABS = 2;


namespace
{

/* Every message also goes to <genDir>/olspro_apache.log: this runs before
 * OLS opens error.log, so LS_* output only reaches stderr / the journal. */
struct Ctx
{
    std::vector<std::string> lines;

    void add(int level, const char *fmt, va_list ap)
    {
        char buf[4096];
        vsnprintf(buf, sizeof(buf), fmt, ap);
        const char *tag = level == 2 ? "ERROR" : level == 1 ? "WARN" : "NOTICE";
        if (level == 2)
            LS_ERROR("[OLSPRO] apacheconf: %s", buf);
        else if (level == 1)
            LS_WARN("[OLSPRO] apacheconf: %s", buf);
        else
            LS_NOTICE("[OLSPRO] apacheconf: %s", buf);
        char ts[32];
        time_t now = time(NULL);
        struct tm tmv;
        localtime_r(&now, &tmv);
        strftime(ts, sizeof(ts), "%Y-%m-%d %H:%M:%S", &tmv);
        lines.push_back(std::string(ts) + " [" + tag + "] " + buf);
    }
    __attribute__((format(printf, 2, 3)))
    void notice(const char *fmt, ...)
    {   va_list ap; va_start(ap, fmt); add(0, fmt, ap); va_end(ap);   }
    __attribute__((format(printf, 2, 3)))
    void warn(const char *fmt, ...)
    {   va_list ap; va_start(ap, fmt); add(1, fmt, ap); va_end(ap);   }
    __attribute__((format(printf, 2, 3)))
    void error(const char *fmt, ...)
    {   va_list ap; va_start(ap, fmt); add(2, fmt, ap); va_end(ap);   }
};


struct Fd
{
    int fd = -1;
    Fd() {}
    explicit Fd(int f) : fd(f) {}
    ~Fd() { if (fd != -1) close(fd); }
    Fd(const Fd &) = delete;
    Fd &operator=(const Fd &) = delete;
};

}  // namespace


/* A directory root may write into: owned by root (or by us when not root),
 * not group/world writable. */
static bool dirIsSafe(int fd, std::string &why)
{
    struct stat st;
    if (fstat(fd, &st) != 0)
    {
        why = strerror(errno);
        return false;
    }
    if (!S_ISDIR(st.st_mode))
    {
        why = "not a directory";
        return false;
    }
    if (st.st_uid != 0 && st.st_uid != geteuid())
    {
        why = "owned by uid " + std::to_string((long)st.st_uid)
              + ", expected root";
        return false;
    }
    if (st.st_mode & (S_IWGRP | S_IWOTH))
    {
        why = "group/world writable";
        return false;
    }
    return true;
}


/* openat() a sub directory, optionally creating it; refuses symlinks and
 * directories another user could write into. */
static int openSafeDir(int parentFd, const char *name, bool create,
                       std::string &why)
{
    if (create && mkdirat(parentFd, name, 0755) != 0 && errno != EEXIST)
    {
        why = std::string("mkdir: ") + strerror(errno);
        return -1;
    }
    int fd = openat(parentFd, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd == -1)
    {
        why = (errno == ELOOP || errno == ENOTDIR)
              ? std::string("is a symlink or not a directory")
              : std::string(strerror(errno));
        return -1;
    }
    if (!dirIsSafe(fd, why))
    {
        close(fd);
        return -1;
    }
    return fd;
}


/* Create a NEW file inside dirFd (O_EXCL|O_NOFOLLOW) and write data. */
static int writeNew(int dirFd, const char *name, const std::string &data,
                    bool doSync)
{
    int fd = openat(dirFd, name,
                    O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0644);
    if (fd == -1)
        return -1;
    const char *p = data.data();
    size_t left = data.size();
    while (left > 0)
    {
        ssize_t n = write(fd, p, left);
        if (n < 0)
        {
            if (errno == EINTR)
                continue;
            int saved = errno;
            close(fd);
            unlinkat(dirFd, name, 0);
            errno = saved;
            return -1;
        }
        p += n;
        left -= (size_t)n;
    }
    if ((doSync && fsync(fd) != 0) || close(fd) != 0)
    {
        int saved = errno;
        unlinkat(dirFd, name, 0);
        errno = saved;
        return -1;
    }
    return 0;
}


/* Replace name inside dirFd atomically: unique temp, fsync, renameat. */
static int replaceAtomic(int dirFd, const std::string &name,
                         const std::string &data)
{
    char suffix[64];
    snprintf(suffix, sizeof(suffix), ".tmp.%d.%ld", (int)getpid(),
             (long)time(NULL));
    std::string tmp = name + suffix;
    unlinkat(dirFd, tmp.c_str(), 0);   // stale leftover; dir is root-only
    if (writeNew(dirFd, tmp.c_str(), data, true) != 0)
        return -1;
    if (renameat(dirFd, tmp.c_str(), dirFd, name.c_str()) != 0)
    {
        int saved = errno;
        unlinkat(dirFd, tmp.c_str(), 0);
        errno = saved;
        return -1;
    }
    return 0;
}


/* rm -rf of name inside parentFd without following symlinks. */
static void removeTree(int parentFd, const char *name, int depth = 0)
{
    if (depth > 8)
        return;
    int fd = openat(parentFd, name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (fd == -1)
    {
        unlinkat(parentFd, name, 0);    // a file or a symlink: drop the link
        return;
    }
    DIR *d = fdopendir(fd);
    if (!d)
    {
        close(fd);
        return;
    }
    std::vector<std::string> names;
    while (struct dirent *e = readdir(d))
        if (strcmp(e->d_name, ".") != 0 && strcmp(e->d_name, "..") != 0)
            names.push_back(e->d_name);
    for (const std::string &n : names)
        if (unlinkat(fd, n.c_str(), 0) != 0)
            removeTree(fd, n.c_str(), depth + 1);
    closedir(d);
    unlinkat(parentFd, name, AT_REMOVEDIR);
}


/* Read the head of the current fragment: hash, vhost count, generation. */
static bool readPrevious(int genFd, std::string &hash, long &vhosts,
                         std::string &gen)
{
    int fd = openat(genFd, SERVER_FRAGMENT, O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (fd == -1)
        return false;
    char buf[1024];
    ssize_t n = read(fd, buf, sizeof(buf) - 1);
    close(fd);
    if (n <= 0)
        return false;
    buf[n] = 0;
    const char *p = strstr(buf, HASH_TAG);
    if (!p)
        return false;
    char h[64], g[128];
    long cnt = 0;
    if (sscanf(p + strlen(HASH_TAG), "%63s vhosts=%ld gen=%127s", h, &cnt, g)
        != 3)
        return false;
    hash = h;
    vhosts = cnt;
    gen = g;
    return true;
}


static std::string replaceAll(std::string s, const std::string &from,
                              const std::string &to)
{
    size_t pos = 0;
    while ((pos = s.find(from, pos)) != std::string::npos)
    {
        s.replace(pos, from.size(), to);
        pos += to.size();
    }
    return s;
}


static void fnv1a(uint64_t &h, const std::string &s)
{
    for (unsigned char c : s)
    {
        h ^= c;
        h *= 1099511628211ULL;
    }
    h ^= 0xff;                // separator, so ("ab","c") != ("a","bc")
    h *= 1099511628211ULL;
}


/* Apache ServerRoot for relative Includes: OLSPRO_APACHE_ROOT, else the
 * ServerRoot directive of the top-level file, else the parent of the conf/
 * directory holding it (/etc/apache2/conf/httpd.conf -> /etc/apache2,
 * /etc/httpd/conf/httpd.conf -> /etc/httpd). */
static std::string apacheRoot(const char *pApacheConf)
{
    const char *pEnv = getenv("OLSPRO_APACHE_ROOT");
    if (pEnv && *pEnv)
        return pEnv;
    FILE *f = fopen(pApacheConf, "r");
    if (f)
    {
        char line[4096];
        while (fgets(line, sizeof(line), f))
        {
            std::vector<std::string> t = tokenize(line);
            if (t.size() >= 2 && strcasecmp(t[0].c_str(), "ServerRoot") == 0
                && !t[1].empty() && t[1][0] == '/')
            {
                fclose(f);
                return t[1];
            }
        }
        fclose(f);
    }
    std::string conf(pApacheConf);
    size_t s = conf.rfind('/');
    std::string dir = (s == std::string::npos || s == 0) ? "/" : conf.substr(0, s);
    size_t s2 = dir.rfind('/');
    if (s2 != std::string::npos && dir.compare(s2 + 1, std::string::npos, "conf") == 0)
        return s2 == 0 ? "/" : dir.substr(0, s2);
    return dir;
}


/* Warnings that mean part of the Apache tree was not read: replacing the
 * fragment would silently drop the vhosts it defines. */
static bool isIncompleteRead(const Warning &w)
{
    return w.message.compare(0, 24, "Include target not found") == 0
           || w.message.compare(0, 16, "cannot read file") == 0
           || w.message.compare(0, 23, "Include depth limit rea") == 0
           || w.message.compare(0, 30, "Include wildcard matched no fi") == 0;
}


static bool envFlag(const char *name)
{
    const char *p = getenv(name);
    return p && *p == '1';
}


static int generate(const char *pServerRoot, bool dryRun, Ctx &ctx,
                    int &genFdOut)
{
    const char *pApacheConf = getenv("OLSPRO_APACHE_CONF");
    if (!pServerRoot || !*pServerRoot)
    {
        ctx.error("server root unknown, skip loading %s", pApacheConf);
        return STARTUP_FAILED;
    }
    bool force = envFlag("OLSPRO_APACHE_FORCE");

    std::string serverRoot(pServerRoot);
    if (serverRoot[serverRoot.size() - 1] != '/')
        serverRoot += '/';
    std::string genDir = serverRoot + GEN_DIR_NAME;

    // The output directory must be one only root can write to; everything
    // below is opened relative to it with O_NOFOLLOW, so a symlink planted
    // by a less privileged user (lsadm owns conf/) cannot redirect a write.
    std::string why;
    Fd rootFd(open(serverRoot.c_str(), O_RDONLY | O_DIRECTORY | O_CLOEXEC));
    if (rootFd.fd == -1 || !dirIsSafe(rootFd.fd, why))
    {
        ctx.error("server root %s is not a safe directory (%s); not "
                  "generating", serverRoot.c_str(),
                  rootFd.fd == -1 ? strerror(errno) : why.c_str());
        return STARTUP_FAILED;
    }
    Fd genFd(openSafeDir(rootFd.fd, GEN_DIR_NAME, !dryRun, why));
    if (genFd.fd == -1 && !dryRun)
    {
        ctx.error("refusing to use %s: %s; not generating", genDir.c_str(),
                  why.c_str());
        return STARTUP_FAILED;
    }
    if (genFd.fd != -1 && !dryRun)
        genFdOut = dup(genFd.fd);

    ParseOptions opt;
    opt.serverRoot = apacheRoot(pApacheConf);
    ctx.notice("loading %s (Apache ServerRoot %s)%s", pApacheConf,
               opt.serverRoot.c_str(), dryRun ? " [config test: no writes]" : "");

    Config cfg;
    bool ok = load(pApacheConf, opt, cfg);

    int incomplete = 0;
    for (const Warning &w : cfg.warnings)
    {
        ctx.warn("%s:%d: %s", w.file.c_str(), w.line, w.message.c_str());
        if (isIncompleteRead(w))
            ++incomplete;
    }

    if (!ok)
    {
        ctx.error("cannot read %s; keeping previous generated config in %s",
                  pApacheConf, genDir.c_str());
        return STARTUP_FAILED;
    }
    if (cfg.vhosts.empty())
    {
        // An empty fragment would silently take every site offline.
        ctx.error("%s produced 0 virtual hosts (%d files read, %zu warnings); "
                  "keeping previous generated config in %s", pApacheConf,
                  cfg.filesRead, cfg.warnings.size(), genDir.c_str());
        return STARTUP_FAILED;
    }
    if (incomplete && !force)
    {
        ctx.error("%d Include/read errors in the Apache config (see warnings "
                  "above); the vhost list may be incomplete, keeping previous "
                  "generated config in %s (OLSPRO_APACHE_FORCE=1 overrides)",
                  incomplete, genDir.c_str());
        return STARTUP_FAILED;
    }

    // Render everything in memory first; nothing is written unless every
    // vhost rendered.
    std::string vhostBase = genDir + "/" + PLACEHOLDER + "/vhosts";
    std::string serverConf = renderServerConf(cfg, vhostBase);

    // Generated vhosts must not follow symlinks across accounts (EA4
    // SymLinksIfOwnerMatch + symlink protection parity).
    for (size_t pos = serverConf.find("allowSymbolLink");
         pos != std::string::npos;
         pos = serverConf.find("allowSymbolLink", pos + 1))
    {
        size_t v = serverConf.find_first_not_of(" \t", pos + 15);
        if (v != std::string::npos && serverConf[v] == '1')
        {
            ctx.error("rendered config contains 'allowSymbolLink 1' "
                      "(cross-account symlink reads); refusing to activate");
            return STARTUP_FAILED;
        }
    }

    struct Out
    {
        std::string id;
        std::string body;
    };
    std::vector<Out> outs;
    std::set<std::string> written;
    uint64_t hash = 1469598103934665603ULL;
    fnv1a(hash, serverConf);
    for (const VHost &v : cfg.vhosts)
    {
        std::string id = vhostId(v);
        if (id.empty() || id[0] == '.' || id.find('/') != std::string::npos)
        {
            ctx.error("%s:%d: unusable vhost id '%s'; not generating",
                      v.file.c_str(), v.line, id.c_str());
            return STARTUP_FAILED;
        }
        if (!written.insert(id).second)
        {
            ctx.warn("%s:%d: duplicate vhost id %s, first definition wins",
                     v.file.c_str(), v.line, id.c_str());
            continue;
        }
        Out o;
        o.id = id;
        o.body = renderVhostConf(v, vhostBase + "/" + id);
        fnv1a(hash, id);
        fnv1a(hash, o.body);
        outs.push_back(std::move(o));
    }
    char hashHex[32];
    snprintf(hashHex, sizeof(hashHex), "%016llx", (unsigned long long)hash);

    std::string prevHash, prevGen;
    long prevCount = 0;
    bool havePrev = genFd.fd != -1
                    && readPrevious(genFd.fd, prevHash, prevCount, prevGen);

    if (havePrev && prevHash == hashHex)
    {
        struct stat st;
        if (fstatat(genFd.fd, prevGen.c_str(), &st, AT_SYMLINK_NOFOLLOW) == 0
            && S_ISDIR(st.st_mode))
        {
            ctx.notice("Apache config unchanged (%zu vhosts, %d files read, "
                       "%zu warnings); keeping %s/%s", outs.size(),
                       cfg.filesRead, cfg.warnings.size(), genDir.c_str(),
                       SERVER_FRAGMENT);
            return STARTUP_GENERATED;
        }
    }

    long drop = havePrev ? prevCount - (long)outs.size() : 0;
    if (drop > MAX_DROP_ABS && drop * 100 > prevCount * MAX_DROP_PCT && !force)
    {
        ctx.error("vhost count would drop from %ld to %zu (more than %d%%); "
                  "keeping previous generated config in %s "
                  "(OLSPRO_APACHE_FORCE=1 overrides)", prevCount, outs.size(),
                  MAX_DROP_PCT, genDir.c_str());
        return STARTUP_FAILED;
    }

    if (dryRun)
    {
        ctx.notice("config test: %s would generate %zu vhosts, %zu listeners "
                   "(nothing written)", pApacheConf, outs.size(),
                   cfg.listens.size());
        return STARTUP_GENERATED;
    }

    // Fresh generation directory: old generations are never modified, so a
    // failure part way leaves the previous fragment fully consistent.
    char genName[64];
    snprintf(genName, sizeof(genName), "%s%ld-%d", GEN_PREFIX,
             (long)time(NULL), (int)getpid());
    removeTree(genFd.fd, genName);
    Fd newGen(openSafeDir(genFd.fd, genName, true, why));
    Fd vhFd(newGen.fd == -1 ? -1 : openSafeDir(newGen.fd, "vhosts", true, why));
    if (vhFd.fd == -1)
    {
        ctx.error("cannot create %s/%s/vhosts: %s; previous generated config "
                  "kept", genDir.c_str(), genName, why.c_str());
        if (newGen.fd != -1)
            removeTree(genFd.fd, genName);
        return STARTUP_FAILED;
    }
    for (const Out &o : outs)
    {
        Fd d(openSafeDir(vhFd.fd, o.id.c_str(), true, why));
        if (d.fd == -1
            || writeNew(d.fd, "vhconf.conf",
                        replaceAll(o.body, PLACEHOLDER, genName), false) != 0)
        {
            ctx.error("cannot write %s/%s/vhosts/%s/vhconf.conf: %s; previous "
                      "generated config kept", genDir.c_str(), genName,
                      o.id.c_str(), d.fd == -1 ? why.c_str() : strerror(errno));
            removeTree(genFd.fd, genName);
            return STARTUP_FAILED;
        }
    }
    // One flush for the whole generation instead of an fsync per file.
#ifdef __linux__
    if (syncfs(newGen.fd) != 0)
        ctx.warn("syncfs %s/%s: %s", genDir.c_str(), genName, strerror(errno));
#else
    sync();
#endif

    char head[256];
    snprintf(head, sizeof(head), "%s%s vhosts=%zu gen=%s\n", HASH_TAG,
             hashHex, outs.size(), genName);
    std::string frag = std::string(head)
                       + replaceAll(serverConf, PLACEHOLDER, genName);
    if (replaceAtomic(genFd.fd, SERVER_FRAGMENT, frag) != 0)
    {
        ctx.error("cannot write %s/%s: %s; previous file kept", genDir.c_str(),
                  SERVER_FRAGMENT, strerror(errno));
        removeTree(genFd.fd, genName);
        return STARTUP_FAILED;
    }

    // The new fragment is in place: drop every other generation.
    {
        int fd = openat(genFd.fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
        DIR *d = fd == -1 ? NULL : fdopendir(fd);
        if (!d && fd != -1)
            close(fd);
        std::vector<std::string> old;
        if (d)
        {
            while (struct dirent *e = readdir(d))
                if (strncmp(e->d_name, GEN_PREFIX, strlen(GEN_PREFIX)) == 0
                    && strcmp(e->d_name, genName) != 0)
                    old.push_back(e->d_name);
            closedir(d);
        }
        for (const std::string &n : old)
            removeTree(genFd.fd, n.c_str());
    }

    ctx.notice("generated %s/%s: %zu vhosts, %zu listens, %d files read, "
               "%zu warnings (generation %s)", genDir.c_str(), SERVER_FRAGMENT,
               outs.size(), cfg.listens.size(), cfg.filesRead,
               cfg.warnings.size(), genName);
    return STARTUP_GENERATED;
}


int generateFromEnv(const char *pServerRoot, bool dryRun)
{
    const char *pApacheConf = getenv("OLSPRO_APACHE_CONF");
    if (!pApacheConf || !*pApacheConf)
        return STARTUP_DISABLED;

    int genFd = -1;
    int ret = STARTUP_FAILED;
    try
    {
        Ctx ctx;
        try
        {
            ret = generate(pServerRoot, dryRun, ctx, genFd);
        }
        catch (const std::exception &e)
        {
            ctx.error("exception while generating from %s: %s; keeping "
                      "previous generated config", pApacheConf, e.what());
            ret = STARTUP_FAILED;
        }
        catch (...)
        {
            ctx.error("unknown exception while generating from %s; keeping "
                      "previous generated config", pApacheConf);
            ret = STARTUP_FAILED;
        }
        if (genFd != -1)
        {
            std::string log;
            for (const std::string &l : ctx.lines)
                log += l + "\n";
            replaceAtomic(genFd, LOG_FILE, log);
        }
    }
    catch (...)
    {
        // Never let an allocation failure here stop the server starting.
        ret = STARTUP_FAILED;
    }
    if (genFd != -1)
        close(genFd);
    return ret;
}

}  // namespace apacheconf
