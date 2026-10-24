/*****************************************************************************
*    OLS PRO - mod_bruteguard: native login / xmlrpc brute-force throttle.   *
*    GPLv3, see GPL.txt                                                      *
*****************************************************************************/
/*
 * Counts POST requests per client IP against well-known credential endpoints
 * (WordPress wp-login.php / xmlrpc.php, Joomla, Drupal, cPanel-style logins)
 * inside a sliding window and answers 429 + Retry-After once the limit is
 * exceeded. Runs before PHP is touched, so a credential-stuffing flood costs
 * a hash lookup instead of a WordPress boot + DB query.
 *
 * Counters are per worker process (no shared memory yet): with N workers the
 * effective limit is up to N * limit. Tunables (environment of the OLS
 * process): OLSPRO_BG_LIMIT (default 10), OLSPRO_BG_WINDOW seconds (60),
 * OLSPRO_BG_BAN seconds (300), OLSPRO_BG_OFF=1 disables.
 */
#include <ls.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include <string>
#include <unordered_map>

#define MNAME               modbruteguard
#define MODULE_VERSION_INFO "0.1"

extern lsi_module_t MNAME;

namespace
{
struct Bucket
{
    time_t windowStart;
    int    count;
    time_t bannedUntil;
};

std::unordered_map<std::string, Bucket> g_buckets;
int    g_limit = 10, g_window = 60, g_ban = 300;
bool   g_off = false;
time_t g_lastSweep = 0;

int envInt(const char *name, int def)
{
    const char *v = getenv(name);
    int n = v ? atoi(v) : 0;
    return n > 0 ? n : def;
}

// Endpoints worth throttling. Matched on the path only (query string ignored).
bool isLoginPath(const char *uri, int len)
{
    static const char *tails[] = {
        "/wp-login.php", "/xmlrpc.php", "/administrator/index.php",
        "/user/login", "/wp-json/jwt-auth/v1/token", NULL
    };
    for (int i = 0; tails[i]; ++i)
    {
        int tl = (int)strlen(tails[i]);
        if (len >= tl && memcmp(uri + len - tl, tails[i], tl) == 0)
            return true;
    }
    return false;
}

void sweep(time_t now)
{
    if (now - g_lastSweep < 60)
        return;
    g_lastSweep = now;
    for (auto it = g_buckets.begin(); it != g_buckets.end();)
        if (it->second.bannedUntil < now && now - it->second.windowStart > g_window)
            it = g_buckets.erase(it);
        else
            ++it;
}
}  // namespace

static int onReqHeader(lsi_param_t *rec)
{
    if (g_off)
        return 0;
    if (g_api->get_req_method(rec->session) != LSI_METHOD_POST)
        return 0;

    int uriLen = 0;
    const char *uri = g_api->get_req_uri(rec->session, &uriLen);
    if (!uri)
        return 0;
    // strip query string
    for (int i = 0; i < uriLen; ++i)
        if (uri[i] == '?')
        {
            uriLen = i;
            break;
        }
    if (!isLoginPath(uri, uriLen))
        return 0;

    int ipLen = 0;
    const char *ip = g_api->get_client_ip(rec->session, &ipLen);
    if (!ip || ipLen <= 0)
        return 0;

    time_t now = time(NULL);
    sweep(now);
    Bucket &b = g_buckets[std::string(ip, ipLen)];
    if (b.windowStart == 0 || now - b.windowStart > g_window)
    {
        b.windowStart = now;
        b.count = 0;
    }
    ++b.count;
    if (b.count > g_limit && b.bannedUntil < now)
        b.bannedUntil = now + g_ban;
    if (b.bannedUntil >= now)
    {
        char ra[16];
        int n = snprintf(ra, sizeof(ra), "%ld", (long)(b.bannedUntil - now) + 1);
        g_api->set_status_code(rec->session, 429);
        g_api->set_resp_header(rec->session, LSI_RSPHDR_UNKNOWN, "Retry-After", 11,
                               ra, n, LSI_HEADEROP_SET);
        return 429;
    }
    return 0;
}

static int onInit(lsi_module_t *module)
{
    (void)module;
    g_off    = getenv("OLSPRO_BG_OFF") != NULL;
    g_limit  = envInt("OLSPRO_BG_LIMIT", 10);
    g_window = envInt("OLSPRO_BG_WINDOW", 60);
    g_ban    = envInt("OLSPRO_BG_BAN", 300);
    return 0;
}

static lsi_serverhook_t server_hooks[] =
{
    { LSI_HKPT_RCVD_REQ_HEADER, onReqHeader, LSI_HOOK_EARLY, LSI_FLAG_ENABLED },
    LSI_HOOK_END
};

LSMODULE_EXPORT lsi_module_t MNAME =
{ LSI_MODULE_SIGNATURE, onInit, NULL, NULL, MODULE_VERSION_INFO, server_hooks, {0} };
