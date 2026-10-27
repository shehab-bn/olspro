/*****************************************************************************
*    OLS PRO - mod_bruteguard: native login / xmlrpc brute-force throttle.   *
*    GPLv3, see GPL.txt                                                      *
*****************************************************************************/
/*
 * Counts POST requests per client address against well-known credential
 * endpoints (WordPress wp-login.php / xmlrpc.php, Joomla, Drupal, cPanel-style
 * logins) inside a fixed window and answers 429 + Retry-After once the limit
 * is exceeded. Runs before PHP is touched, so a credential-stuffing flood costs
 * a hash lookup instead of a WordPress boot + DB query.
 *
 * Counters live in an LRU shared-memory hash (pool "olsprobg", hash "bglru"),
 * so the limit is global across all worker processes. The table is bounded:
 * idle entries are trimmed once their window and ban are over, and when it
 * holds more than OLSPRO_BG_MAXENTRIES entries the least recently used ones
 * are evicted. IPv4 clients are keyed by address, IPv6 clients by their /64.
 * If the shared memory cannot be opened the module falls back to (also
 * bounded) per-process counters.
 *
 * Tunables (environment of the OLS process), see README.md:
 *   OLSPRO_BG_LIMIT      (10)     POSTs allowed per window per client
 *   OLSPRO_BG_WINDOW     (60)     window length, seconds
 *   OLSPRO_BG_BAN        (300)    ban length once the limit is exceeded, s
 *   OLSPRO_BG_MAXENTRIES (100000) max tracked clients (LRU-evicted beyond)
 *   OLSPRO_BG_PATHS               extra comma-separated path tails to guard
 *   OLSPRO_BG_ALLOW               comma-separated IPs / CIDRs never throttled
 *   OLSPRO_BG_OFF=1               disable the module
 */
#include <ls.h>
#include <lsr/ls_shm.h>
#include <lsr/xxhash.h>
#include <shm/lsshmhash.h>

#include <arpa/inet.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <string>
#include <unordered_map>
#include <vector>

#define MNAME               modbruteguard
#define MODULE_VERSION_INFO "0.3"

extern lsi_module_t MNAME;

namespace
{
// Fixed-size value stored per client key in shared memory. The shm hash only
// guarantees 4-byte alignment of values, so every field is a 32-bit word and
// is touched with 32-bit atomics. Seconds since the epoch fit in uint32_t
// until 2106.
//
// state packs the window id and the count into one word,
//   (windowId & 0xFFFF) << 16 | min(count, 0xFFFF)
// so a window rollover and an increment are a single CAS and can neither
// lose increments nor count a stale window's hits against the new one.
struct ShmBucket
{
    uint32_t state;
    uint32_t bannedUntil;
    uint32_t reserved[2];
};

// Per-process fallback when shared memory is unavailable.
struct Bucket
{
    time_t windowStart;
    int    count;
    time_t bannedUntil;
};

// Parsed client / allow-list address. v4-mapped IPv6 is folded to IPv4.
struct Addr
{
    int     fam;        // AF_INET or AF_INET6
    uint8_t b[16];
};

struct Cidr
{
    Addr addr;
    int  bits;
};

const char *const SHM_POOL = "olsprobg";
// New name for the LRU table: an existing SHM file may still hold the v0.2
// non-LRU "bruteguard" table, and opening a table with different flags fails.
const char *const SHM_HASH = "bglru";
const int TRIM_INTERVAL = 10;   // seconds between expiry trims, per worker

ls_shmhash_t *g_hash = NULL;
std::unordered_map<std::string, Bucket> g_buckets;
std::vector<std::string> g_tails;
std::vector<std::string> g_restRoutes;  // "/jwt-auth/v1/token" for "?rest_route="
std::vector<Cidr> g_allow;
int    g_limit = 10, g_window = 60, g_ban = 300, g_maxEntries = 100000;
bool   g_off = false;
time_t g_lastSweep = 0;
time_t g_lastShmTrim = 0;

int envInt(const char *name, int def)
{
    const char *v = getenv(name);
    int n = v ? atoi(v) : 0;
    return n > 0 ? n : def;
}

// Split a comma-separated env value, trimming spaces, dropping empties.
void envList(const char *name, std::vector<std::string> &out)
{
    const char *v = getenv(name);
    if (!v)
        return;
    std::string s(v);
    size_t pos = 0;
    while (pos <= s.size())
    {
        size_t comma = s.find(',', pos);
        if (comma == std::string::npos)
            comma = s.size();
        size_t b = pos, e = comma;
        while (b < e && (s[b] == ' ' || s[b] == '\t'))
            ++b;
        while (e > b && (s[e - 1] == ' ' || s[e - 1] == '\t'))
            --e;
        if (e > b)
            out.push_back(s.substr(b, e - b));
        pos = comma + 1;
    }
}

bool parseAddr(const char *ip, int len, Addr &a)
{
    char buf[64];
    if (!ip || len <= 0 || len >= (int)sizeof(buf))
        return false;
    memcpy(buf, ip, len);
    buf[len] = 0;
    if (memchr(buf, ':', len))
    {
        char *pct = strchr(buf, '%');   // zone id
        if (pct)
            *pct = 0;
        if (inet_pton(AF_INET6, buf, a.b) != 1)
            return false;
        static const uint8_t mapped[12] =
        { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff };
        if (memcmp(a.b, mapped, 12) == 0)
        {
            memmove(a.b, a.b + 12, 4);
            a.fam = AF_INET;
        }
        else
            a.fam = AF_INET6;
        return true;
    }
    if (inet_pton(AF_INET, buf, a.b) != 1)
        return false;
    a.fam = AF_INET;
    return true;
}

bool parseCidr(const std::string &s, Cidr &c)
{
    size_t slash = s.find('/');
    std::string ip = s.substr(0, slash);
    if (!parseAddr(ip.data(), (int)ip.size(), c.addr))
        return false;
    int maxBits = c.addr.fam == AF_INET ? 32 : 128;
    c.bits = maxBits;
    if (slash != std::string::npos)
    {
        const char *p = s.c_str() + slash + 1;
        char *end = NULL;
        long v = strtol(p, &end, 10);
        if (end == p || *end != 0 || v < 0 || v > maxBits)
            return false;
        c.bits = (int)v;
    }
    return true;
}

bool cidrMatch(const Cidr &c, const Addr &a)
{
    if (c.addr.fam != a.fam)
        return false;
    int full = c.bits / 8, rem = c.bits % 8;
    if (full && memcmp(c.addr.b, a.b, full) != 0)
        return false;
    if (rem)
    {
        uint8_t mask = (uint8_t)(0xFF << (8 - rem));
        if ((c.addr.b[full] & mask) != (a.b[full] & mask))
            return false;
    }
    return true;
}

bool isAllowed(const Addr &a)
{
    for (size_t i = 0; i < g_allow.size(); ++i)
        if (cidrMatch(g_allow[i], a))
            return true;
    return false;
}

// Counter key: IPv4 by address, IPv6 by /64 (one subscriber / host usually
// owns a whole /64, so per-address keys would be trivially rotated).
int makeKey(const Addr &a, char *key)
{
    if (a.fam == AF_INET)
    {
        key[0] = '4';
        memcpy(key + 1, a.b, 4);
        return 5;
    }
    key[0] = '6';
    memcpy(key + 1, a.b, 8);
    return 9;
}

// Guarded if a tail occurs in the path and is followed by end-of-path or '/'
// (PATH_INFO: "/xmlrpc.php/x" still runs xmlrpc.php).
bool isLoginPath(const char *uri, int len)
{
    for (size_t i = 0; i < g_tails.size(); ++i)
    {
        const std::string &t = g_tails[i];
        int tl = (int)t.size();
        if (tl == 0)
            continue;
        for (int pos = 0; pos + tl <= len; ++pos)
        {
            if (uri[pos] != t[0] || memcmp(uri + pos, t.data(), tl) != 0)
                continue;
            if (pos + tl == len || uri[pos + tl] == '/')
                return true;
        }
    }
    return false;
}

int hexVal(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

// WordPress also routes REST calls via "?rest_route=/jwt-auth/v1/token".
bool isGuardedRestRoute(const char *qs, int len)
{
    if (!qs || len <= 0 || g_restRoutes.empty())
        return false;
    static const char name[] = "rest_route=";
    const int nl = (int)sizeof(name) - 1;
    for (int pos = 0; pos + nl <= len; ++pos)
    {
        if ((pos != 0 && qs[pos - 1] != '&') || memcmp(qs + pos, name, nl) != 0)
            continue;
        char val[256];
        int vl = 0;
        for (int i = pos + nl; i < len && qs[i] != '&'
             && vl < (int)sizeof(val) - 1; ++i)
        {
            char c = qs[i];
            if (c == '%' && i + 2 < len && hexVal(qs[i + 1]) >= 0
                && hexVal(qs[i + 2]) >= 0)
            {
                c = (char)(hexVal(qs[i + 1]) * 16 + hexVal(qs[i + 2]));
                i += 2;
            }
            else if (c == '+')
                c = ' ';
            val[vl++] = c;
        }
        for (size_t r = 0; r < g_restRoutes.size(); ++r)
        {
            const std::string &rt = g_restRoutes[r];
            int rl = (int)rt.size();
            if (vl >= rl && memcmp(val, rt.data(), rl) == 0
                && (vl == rl || val[rl] == '/'))
                return true;
        }
    }
    return false;
}

lsi_hash_key_t hashBuf(const void *s, size_t len)
{
    return XXH32(s, len, 0);
}

int evictCb(LsShmHash::iterator iter, void *arg)
{
    (void)iter;
    int *budget = (int *)arg;
    if (*budget <= 0)
        return -1;      // stop
    --*budget;
    return 1;           // delete
}

// Keep the table bounded. Called right after a new entry was created.
void enforceCap(time_t now)
{
    LsShmHash *h = (LsShmHash *)g_hash;
    int n = (int)h->size();
    if (n <= g_maxEntries)
        return;
    // Evict the least recently used entries down to 90% of the cap so this
    // does not run on every insert while under a flood.
    int budget = n - g_maxEntries + g_maxEntries / 10;
    h->trim(now + 3600, evictCb, &budget);
}

// Drop entries whose window and ban are both over.
void trimExpired(time_t now)
{
    if (now - g_lastShmTrim < TRIM_INTERVAL)
        return;
    g_lastShmTrim = now;
    int keep = (g_window > g_ban ? g_window : g_ban) + 1;
    ((LsShmHash *)g_hash)->trim(now - keep, NULL, NULL);
}

// Shared-memory path. Returns seconds remaining on the ban (>0 => throttle),
// 0 => allow, -1 => shm unusable for this request (caller falls back).
//
// ls_shmhash_get() does find-or-create under the hash's own lock (and marks
// the entry most recently used), so concurrent first hits from one client
// land on a single entry. The counters are then updated with 32-bit CAS.
long checkShm(const char *key, int keyLen, time_t now)
{
    trimExpired(now);

    int valLen = (int)sizeof(ShmBucket);
    int flags = LSI_SHM_INIT;
    ls_shmoff_t off = ls_shmhash_get(g_hash, (const uint8_t *)key, keyLen,
                                     &valLen, &flags);
    if (off == 0 || valLen < (int)sizeof(ShmBucket))
        return -1;
    if (flags & LSI_SHM_CREATED)
        enforceCap(now);    // our entry is now the newest, never evicted here
    ShmBucket *b = (ShmBucket *)ls_shmhash_off2ptr(g_hash, off);
    if (!b)
        return -1;

    uint32_t now32 = (uint32_t)now;
    uint32_t wid = (now32 / (uint32_t)g_window) & 0xFFFF;
    uint32_t old = __atomic_load_n(&b->state, __ATOMIC_ACQUIRE);
    uint32_t cnt, neu;
    do
    {
        uint32_t ow = old >> 16, oc = old & 0xFFFF;
        uint32_t w = wid;
        // Same window, or another worker's clock already ticked into the
        // next one: keep counting rather than resetting.
        if (ow == wid || ow == ((wid + 1) & 0xFFFF))
        {
            w = ow;
            cnt = oc < 0xFFFF ? oc + 1 : 0xFFFF;
        }
        else
            cnt = 1;
        neu = (w << 16) | cnt;
    }
    while (!__atomic_compare_exchange_n(&b->state, &old, neu, false,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE));

    uint32_t bu = __atomic_load_n(&b->bannedUntil, __ATOMIC_ACQUIRE);
    if (cnt > (uint32_t)g_limit && bu < now32)
    {
        // On failure another worker set the ban first and bu now holds it.
        uint32_t want = now32 + (uint32_t)g_ban;
        if (__atomic_compare_exchange_n(&b->bannedUntil, &bu, want, false,
                                        __ATOMIC_ACQ_REL, __ATOMIC_ACQUIRE))
            bu = want;
    }
    if (bu >= now32)
        return (long)(bu - now32) + 1;
    return 0;
}

void sweep(time_t now, bool force)
{
    if (!force && now - g_lastSweep < 60)
        return;
    g_lastSweep = now;
    for (auto it = g_buckets.begin(); it != g_buckets.end();)
        if (it->second.bannedUntil < now && now - it->second.windowStart > g_window)
            it = g_buckets.erase(it);
        else
            ++it;
}

// Per-process fallback, same semantics as the shm path, also bounded.
long checkLocal(const char *key, int keyLen, time_t now)
{
    sweep(now, false);
    if (g_buckets.size() >= (size_t)g_maxEntries)
    {
        sweep(now, true);
        if (g_buckets.size() >= (size_t)g_maxEntries)
            g_buckets.clear();
    }
    Bucket &b = g_buckets[std::string(key, keyLen)];
    if (b.windowStart == 0 || now - b.windowStart > g_window)
    {
        b.windowStart = now;
        b.count = 0;
    }
    ++b.count;
    if (b.count > g_limit && b.bannedUntil < now)
        b.bannedUntil = now + g_ban;
    if (b.bannedUntil >= now)
        return (long)(b.bannedUntil - now) + 1;
    return 0;
}
}  // namespace

static void setRetryAfter(const lsi_session_t *session, long secs)
{
    char ra[24];
    int n = snprintf(ra, sizeof(ra), "%ld", secs);
    g_api->set_resp_header(session, LSI_RSPHDR_UNKNOWN, "Retry-After", 11,
                           ra, n, LSI_HEADEROP_SET);
}

static int releaseData(void *p)
{
    (void)p;    // the "pointer" is the Retry-After value itself
    return 0;
}

// The error-page path (buildErrorResponse -> resetResp) drops headers set at
// RCVD_REQ_HEADER, so Retry-After is (re)added when the 429 headers go out.
// Enabled per session only for throttled requests.
static int onSendRespHeader(lsi_param_t *rec)
{
    long secs = (long)(intptr_t)g_api->get_module_data(rec->session, &MNAME,
                                                       LSI_DATA_HTTP);
    if (secs > 0 && g_api->get_status_code(rec->session) == 429)
        setRetryAfter(rec->session, secs);
    return LSI_OK;
}

static int onReqHeader(lsi_param_t *rec)
{
    if (g_off)
        return LSI_OK;
    if (g_api->get_req_method(rec->session) != LSI_METHOD_POST)
        return LSI_OK;

    int uriLen = 0;
    const char *uri = g_api->get_req_uri(rec->session, &uriLen);
    if (!uri)
        return LSI_OK;
    // strip query string
    for (int i = 0; i < uriLen; ++i)
        if (uri[i] == '?')
        {
            uriLen = i;
            break;
        }
    if (!isLoginPath(uri, uriLen))
    {
        int qsLen = 0;
        const char *qs = g_api->get_req_query_string(rec->session, &qsLen);
        if (!isGuardedRestRoute(qs, qsLen))
            return LSI_OK;
    }

    int ipLen = 0;
    const char *ip = g_api->get_client_ip(rec->session, &ipLen);
    if (!ip || ipLen <= 0)
        return LSI_OK;

    char key[72];
    int keyLen;
    Addr a;
    if (parseAddr(ip, ipLen, a))
    {
        if (isAllowed(a))
            return LSI_OK;
        keyLen = makeKey(a, key);
    }
    else
    {
        key[0] = 'r';
        keyLen = ipLen < (int)sizeof(key) - 1 ? ipLen : (int)sizeof(key) - 1;
        memcpy(key + 1, ip, keyLen);
        ++keyLen;
    }

    time_t now = time(NULL);
    long retryAfter = -1;
    if (g_hash)
        retryAfter = checkShm(key, keyLen, now);
    if (retryAfter < 0)
        retryAfter = checkLocal(key, keyLen, now);
    if (retryAfter > 0)
    {
        g_api->set_status_code(rec->session, 429);
        setRetryAfter(rec->session, retryAfter);
        g_api->set_module_data(rec->session, &MNAME, LSI_DATA_HTTP,
                               (void *)(intptr_t)retryAfter);
        int hkpt = LSI_HKPT_SEND_RESP_HEADER;
        g_api->enable_hook(rec->session, &MNAME, 1, &hkpt, 1);
        // Deny via LSI_ERROR: the session then takes the status set above
        // (stored as the SC_429 index). Returning the raw number 429 would be
        // used as a status-code *index* and read past the status table.
        return LSI_ERROR;
    }
    return LSI_OK;
}

static int onInit(lsi_module_t *module)
{
    (void)module;
    g_off        = getenv("OLSPRO_BG_OFF") != NULL;
    g_limit      = envInt("OLSPRO_BG_LIMIT", 10);
    g_window     = envInt("OLSPRO_BG_WINDOW", 60);
    g_ban        = envInt("OLSPRO_BG_BAN", 300);
    g_maxEntries = envInt("OLSPRO_BG_MAXENTRIES", 100000);
    if (g_limit > 60000)        // packed counter saturates at 0xFFFF
        g_limit = 60000;
    if (g_maxEntries < 100)
        g_maxEntries = 100;

    static const char *defTails[] = {
        "/wp-login.php", "/xmlrpc.php", "/administrator/index.php",
        "/user/login", "/wp-json/jwt-auth/v1/token", NULL
    };
    g_tails.clear();
    for (int i = 0; defTails[i]; ++i)
        g_tails.push_back(defTails[i]);
    envList("OLSPRO_BG_PATHS", g_tails);
    g_restRoutes.clear();
    for (size_t i = 0; i < g_tails.size(); ++i)
        if (g_tails[i].compare(0, 9, "/wp-json/") == 0)
            g_restRoutes.push_back(g_tails[i].substr(8));

    std::vector<std::string> allow;
    envList("OLSPRO_BG_ALLOW", allow);
    g_allow.clear();
    for (size_t i = 0; i < allow.size(); ++i)
    {
        Cidr c;
        if (parseCidr(allow[i], c))
            g_allow.push_back(c);
        else
            g_api->log(NULL, LSI_LOG_WARN,
                       "[bruteguard] ignoring invalid OLSPRO_BG_ALLOW entry '%s'\n",
                       allow[i].c_str());
    }

    if (g_off)
        return LSI_OK;
    g_api->init_module_data(&MNAME, releaseData, LSI_DATA_HTTP);
    ls_shmpool_t *pool = ls_shm_opengpool(SHM_POOL, 0);
    if (pool)
        g_hash = lsi_shmlruhash_open(pool, SHM_HASH, 0, hashBuf, memcmp,
                                     LSSHM_FLAG_LRU);
    if (!g_hash)
        g_api->log(NULL, LSI_LOG_WARN,
                   "[bruteguard] shared memory unavailable, using per-process "
                   "counters (limit is per worker)\n");
    // never fail server start-up because of this module
    return LSI_OK;
}

static lsi_serverhook_t server_hooks[] =
{
    { LSI_HKPT_RCVD_REQ_HEADER, onReqHeader, LSI_HOOK_EARLY, LSI_FLAG_ENABLED },
    { LSI_HKPT_SEND_RESP_HEADER, onSendRespHeader, LSI_HOOK_LAST, 0 },
    LSI_HOOK_END
};

LSMODULE_EXPORT lsi_module_t MNAME =
{ LSI_MODULE_SIGNATURE, onInit, NULL, NULL, MODULE_VERSION_INFO, server_hooks, {0} };
