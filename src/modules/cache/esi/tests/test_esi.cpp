/*****************************************************************************
*    OLS PRO - ESI parser / assembler tests (std-only).                      *
*    GPLv3, see GPL.txt                                                      *
*****************************************************************************/
#include "../esiparser.h"

#include <chrono>
#include <cstdio>
#include <map>
#include <stdexcept>
#include <string>

// Per-case wall-clock bound for the pathological / amplification inputs.
// Sanitizer builds are several times slower, so run.sh passes a looser one.
#ifndef ESI_TIME_BOUND
#define ESI_TIME_BOUND 0.25
#endif
// maxParseBytes (32 MB) of dense include tags is ~0.3 s by design; the real
// guard is the fetch count, this bound only catches gross regressions.
#ifndef ESI_AMP_BOUND
#define ESI_AMP_BOUND 2.0
#endif

static int g_fail = 0;
static int g_pass = 0;

#define CHECK(cond) do { if (cond) ++g_pass; else { ++g_fail; \
    fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #cond); } } while (0)

#define CHECK_EQ(a, b) do { std::string _a(a), _b(b); if (_a == _b) ++g_pass; \
    else { ++g_fail; fprintf(stderr, "FAIL %s:%d:\n  got:  [%s]\n  want: [%s]\n", \
    __FILE__, __LINE__, _a.c_str(), _b.c_str()); } } while (0)

static std::map<std::string, std::string> g_store;

static std::optional<std::string> fetchMap(const std::string &src)
{
    auto it = g_store.find(src);
    if (it == g_store.end())
        return std::nullopt;
    return it->second;
}

static std::string assemble(const std::string &body, bool *ok = nullptr,
                            const esi::Limits &lim = esi::Limits())
{
    esi::AssembleResult r = esi::resolve(body, fetchMap, lim);
    if (ok)
        *ok = r.ok;
    return r.ok ? r.body : "<<ERR:" + r.error + ">>";
}

static void testPlain()
{
    esi::ParseResult r = esi::parse("hello <b>world</b>");
    CHECK(r.frags.size() == 1);
    CHECK(!r.hasEsi);
    CHECK(esi::parse("").frags.empty());
    CHECK(!esi::containsEsi("<es i:include src=x/>"));
    CHECK(esi::containsEsi("a<!--esi b-->"));
}

static void testInclude()
{
    g_store = { { "/a", "AAA" }, { "/b?x=1&y=2", "BBB" }, { "/c", "CCC" } };
    CHECK_EQ(assemble("1<esi:include src=\"/a\"/>2"), "1AAA2");
    CHECK_EQ(assemble("1<esi:include src='/a' />2"), "1AAA2");
    CHECK_EQ(assemble("1<esi:include src=/a />2"), "1AAA2");
    CHECK_EQ(assemble("1<esi:include\n  src = \"/a\"\n/>2"), "1AAA2");
    CHECK_EQ(assemble("1<esi:include src=\"/a\"></esi:include>2"), "1AAA2");
    CHECK_EQ(assemble("1<esi:include src=\"/a\">  </esi:include>2"), "1AAA2");
    // entity decoding in attribute
    CHECK_EQ(assemble("<esi:include src=\"/b?x=1&amp;y=2\"/>"), "BBB");
    // '>' and quotes inside quoted values
    g_store["/q?a>b"] = "Q";
    CHECK_EQ(assemble("<esi:include src=\"/q?a>b\"/>"), "Q");
    g_store["/it's"] = "APOS";
    CHECK_EQ(assemble("<esi:include src=\"/it's\"/>"), "APOS");
    g_store["/say\"hi\""] = "DQ";
    CHECK_EQ(assemble("<esi:include src='/say\"hi\"'/>"), "DQ");

    esi::ParseResult r = esi::parse("x<esi:include src=\"/a\" alt=\"/c\" "
                                    "onerror=\"continue\"/>y");
    CHECK(r.frags.size() == 3);
    CHECK(r.includes == 1);
    CHECK(r.frags[1].kind == esi::Fragment::INCLUDE);
    CHECK_EQ(r.frags[1].src, "/a");
    CHECK_EQ(r.frags[1].alt, "/c");
    CHECK(r.frags[1].onErrorContinue);
    CHECK_EQ(std::string(r.frags[0].text), "x");
    CHECK_EQ(std::string(r.frags[2].text), "y");
}

static void testOnError()
{
    g_store = { { "/alt", "ALT" } };
    bool ok = true;
    CHECK_EQ(assemble("a<esi:include src=\"/miss\" alt=\"/alt\"/>b"), "aALTb");
    CHECK_EQ(assemble("a<esi:include src=\"/miss\" onerror=\"continue\"/>b"),
             "ab");
    std::string out = assemble("a<esi:include src=\"/miss\"/>b", &ok);
    CHECK(!ok);
    CHECK(out.find("/miss") != std::string::npos);
    // alt also missing, continue
    CHECK_EQ(assemble("a<esi:include src=\"/m1\" alt=\"/m2\" "
                      "onerror=\"continue\"/>b"), "ab");
    // onerror value other than continue is not continue
    assemble("<esi:include src=\"/m\" onerror=\"abort\"/>", &ok);
    CHECK(!ok);
}

static void testRemoveCommentWrapper()
{
    g_store = { { "/a", "AAA" } };
    CHECK_EQ(assemble("1<esi:remove><a href=/x>fallback</a></esi:remove>2"),
             "12");
    CHECK_EQ(assemble("1<esi:comment text=\"note\"/>2"), "12");
    CHECK_EQ(assemble("1<esi:comment text=\"note\"></esi:comment>2"), "12");
    CHECK_EQ(assemble("1<!--esi <esi:include src=\"/a\"/> -->2"), "1 AAA 2");
    CHECK_EQ(assemble("1<!--esi<p>raw</p>-->2"), "1<p>raw</p>2");
    // normal HTML comments untouched
    CHECK_EQ(assemble("<!-- not esi -->x"), "<!-- not esi -->x");
    CHECK_EQ(assemble("1<esi:remove/>2"), "12");
}

static void testMalformed()
{
    g_store = { { "/a", "AAA" } };
    const char *lits[] = {
        "<esi:include src=\"/a\"",               // unterminated tag
        "<esi:include src=\"/a/>",               // unterminated quote
        "<esi:include/>",                        // no src
        "<esi:include src=\"\"/>",               // empty src
        "<esi:includes src=\"/a\"/>",            // wrong element name
        "<esi:remove>never closed",
        "<!--esi never closed",
        "<esi:",
        "<esi",
        "<",
        "<esi:comment text='x'",
        "<esi:comment>open",
        "<esi:try><esi:attempt>x</esi:attempt></esi:try>", // unsupported
        "</esi:include>",
        "<esi:include src=\"/a\" <b>/>",         // '<' inside tag
    };
    for (const char *s : lits)
    {
        bool ok = false;
        CHECK_EQ(assemble(s, &ok), s);
        CHECK(ok);
    }
    // malformed followed by a valid include still resolves the valid one
    CHECK_EQ(assemble("<esi:include src=\"/a\" <esi:include src=\"/a\"/>"),
             "<esi:include src=\"/a\" AAA");
    CHECK_EQ(assemble("<esi:remove>x <!--esi y --> z"),
             "<esi:remove>x  y  z");
}

static void testNesting()
{
    g_store = {
        { "/l1", "[1<esi:include src=\"/l2\"/>]" },
        { "/l2", "[2<esi:include src=\"/l3\"/>]" },
        { "/l3", "[3]" },
        { "/loop", "L<esi:include src=\"/loop\" onerror=\"continue\"/>" },
        { "/bad", "B<esi:include src=\"/nope\"/>" },
    };
    CHECK_EQ(assemble("<esi:include src=\"/l1\"/>"), "[1[2[3]]]");

    esi::Limits lim;
    lim.maxDepth = 2;
    bool ok = true;
    assemble("<esi:include src=\"/l1\"/>", &ok, lim);
    CHECK(!ok);         // /l3 is at depth 2 -> fails, no onerror -> fatal

    // self-include loop terminates at maxDepth thanks to onerror=continue
    std::string out = assemble("<esi:include src=\"/loop\"/>", &ok);
    CHECK(ok);
    CHECK_EQ(out, "LLLLL");

    // nested failure rolls back the fragment and falls through to alt
    g_store["/fallback"] = "FB";
    CHECK_EQ(assemble("x<esi:include src=\"/bad\" alt=\"/fallback\"/>y"),
             "xFBy");
    CHECK_EQ(assemble("x<esi:include src=\"/bad\" onerror=\"continue\"/>y"),
             "xy");

    // maxIncludes bounds fan-out
    lim = esi::Limits();
    lim.maxIncludes = 3;
    g_store["/a"] = "A";
    std::string body;
    for (int i = 0; i < 10; ++i)
        body += "<esi:include src=\"/a\" onerror=\"continue\"/>";
    CHECK_EQ(assemble(body, &ok, lim), "AAA");

    // maxOutput is fatal
    lim = esi::Limits();
    lim.maxOutput = 4;
    assemble("12345", &ok, lim);
    CHECK(!ok);
}

static void testHuge()
{
    g_store = { { "/a", "A" } };
    using clk = std::chrono::steady_clock;

    // 8 MB of plain HTML: fast path.
    std::string big(8u << 20, 'x');
    auto t0 = clk::now();
    bool ok = false;
    std::string out = assemble(big, &ok);
    CHECK(ok && out.size() == big.size());

    // 200k includes.
    std::string many;
    for (int i = 0; i < 200000; ++i)
        many += "<p><esi:include src=\"/a\"/></p>";
    esi::Limits lim;
    lim.maxIncludes = 1000000;
    esi::ParseResult pr = esi::parse(many, lim);
    CHECK(pr.includes == 200000 && !pr.truncated);
    // default cap: only maxIncludes fragments materialised, rest literal
    pr = esi::parse(many);
    CHECK(pr.includes == 256 && pr.truncated && pr.ok);
    CHECK(pr.frags.size() <= 2 * 256 + 1);
    out = assemble(many, &ok, lim);
    CHECK(ok && out.size() == 200000u * 8);

    // Pathological: 1 MB of unterminated openers must stay linear-ish.
    std::string evil;
    while (evil.size() < (1u << 20))
        evil += "<!--esi<esi:remove><esi:comment>";
    out = assemble(evil, &ok);
    CHECK(ok && out == evil);
    std::string evil2;
    while (evil2.size() < (1u << 20))
        evil2 += "<esi:include src=\"";
    out = assemble(evil2, &ok);
    CHECK(ok && out == evil2);
    double secs = std::chrono::duration<double>(clk::now() - t0).count();
    fprintf(stderr, "huge-input tests: %.2fs\n", secs);
    CHECK(secs < 10.0);

    // Quadratic regressions (review 10-27): unterminated openers *inside* a
    // terminated <!--esi ... --> window. Each 1 MB case must be ~linear.
    std::string rem, cmt;
    while (rem.size() < (1u << 20))
        rem += "<esi:remove>";
    while (cmt.size() < (1u << 20))
        cmt += "<!--esi";
    const std::string cases[] = {
        evil + "-->",
        "<!--esi" + rem + "-->",
        cmt + "-->",
        "<!--esi" + evil2 + "-->",
    };
    for (const std::string &c : cases)
    {
        auto t1 = clk::now();
        esi::AssembleResult r = esi::resolve(c, fetchMap);
        double s1 = std::chrono::duration<double>(clk::now() - t1).count();
        fprintf(stderr, "  pathological %zu KB: %.3fs\n", c.size() >> 10, s1);
        CHECK(r.ok);
        CHECK(s1 < ESI_TIME_BOUND);
    }
}

static void testBudgetAndSafety()
{
    using clk = std::chrono::steady_clock;
    bool ok = true;

    // CPU amplification: a 1 MB fragment that only includes itself with
    // onerror=continue produces no output; maxParseBytes stops it.
    std::string f;
    while (f.size() < (1u << 20))
        f += "<esi:include src=\"/F\" onerror=\"continue\"/>";
    g_store = { { "/F", f } };
    auto t0 = clk::now();
    esi::AssembleResult r = esi::resolve("<esi:include src=\"/F\"/>",
                                         fetchMap);
    double secs = std::chrono::duration<double>(clk::now() - t0).count();
    fprintf(stderr, "  self-include amplification: %.3fs, %zu fetches\n",
            secs, r.fetched);
    CHECK(!r.ok);
    CHECK(r.error.find("maxParseBytes") != std::string::npos);
    CHECK(r.fetched <= 33);
    CHECK(r.body.empty());
    CHECK(secs < ESI_AMP_BOUND);

    // src / alt policy: host-relative only, no control bytes.
    g_store = { { "/a", "AAA" }, { "/alt", "ALT" },
                { "/a\r\nX-Evil: 1", "INJ" },
                { "http://127.0.0.1:2087/json-api", "WHM" },
                { "//other/x", "OTHER" }, { "/\\other/x", "OTHER" },
                { "/a b", "SP" } };
    CHECK(esi::isSafeSrc("/a?x=1&y=2"));
    CHECK(esi::isSafeSrc("/"));
    CHECK(!esi::isSafeSrc(""));
    CHECK(!esi::isSafeSrc("a"));
    CHECK(!esi::isSafeSrc("//other/x"));
    CHECK(!esi::isSafeSrc("/\\other"));
    CHECK(!esi::isSafeSrc("http://127.0.0.1:2087/"));
    CHECK(!esi::isSafeSrc("/a\r\nX: 1"));
    CHECK(!esi::isSafeSrc("/a b"));
    CHECK(!esi::isSafeSrc(std::string("/a\x7f", 3)));
    const char *bad[] = {
        "<esi:include src=\"/a\r\nX-Evil: 1\" onerror=\"continue\"/>",
        "<esi:include src=\"/a&#13;\" onerror=\"continue\"/>",
        "<esi:include src=\"http://127.0.0.1:2087/json-api\" onerror=\"continue\"/>",
        "<esi:include src=\"//other/x\" onerror=\"continue\"/>",
        "<esi:include src='/\\other/x' onerror=\"continue\"/>",
        "<esi:include src='/a b' onerror=\"continue\"/>",
    };
    for (const char *b : bad)
        CHECK_EQ(assemble(std::string("x") + b + "y"), "xy");
    // unsafe src without onerror is a failed include (fatal)
    assemble("<esi:include src=\"//other/x\"/>", &ok);
    CHECK(!ok);
    // unsafe src, safe alt -> alt; unsafe alt is never fetched
    CHECK_EQ(assemble("<esi:include src=\"//other/x\" alt=\"/alt\"/>"), "ALT");
    CHECK_EQ(assemble("<esi:include src=\"/miss\" alt=\"//other/x\" "
                      "onerror=\"continue\"/>"), "");
    esi::ParseResult pr = esi::parse("<esi:include src=\"//o/x\"/>");
    CHECK(pr.includes == 1 && pr.frags[0].src.empty());

    // Exceptions from the fetcher never escape resolve().
    esi::Fetcher thrower = [](const std::string &) -> std::optional<std::string>
    { throw std::runtime_error("boom"); };
    r = esi::resolve("a<esi:include src=\"/a\"/>b", thrower);
    CHECK(!r.ok && r.body.empty() && !r.error.empty());
    r = esi::resolve("a<esi:include src=\"/a\"/>b", esi::Fetcher());
    CHECK(!r.ok);
}

static void testSlashAndContent()
{
    g_store = { { "/blog/", "SLASH" }, { "/blog", "NOSLASH" }, { "/a", "AAA" } };
    // unquoted value ending in '/' keeps its slash
    CHECK_EQ(assemble("1<esi:include src=/blog/>2"), "1SLASH2");
    CHECK_EQ(assemble("1<esi:include src=/blog />2"), "1NOSLASH2");
    CHECK_EQ(assemble("1<esi:include src=\"/blog/\"/>2"), "1SLASH2");
    // include content is dropped with its close tag
    CHECK_EQ(assemble("1<esi:include src=\"/a\">fallback</esi:include>2"),
             "1AAA2");
    // ...but never swallows a following ESI element
    CHECK_EQ(assemble("<esi:include src=\"/a\">x<esi:include src=\"/a\"/>"
                      "</esi:include>"), "AAAxAAA</esi:include>");
    // close tag beyond maxTagLen: include is treated as empty
    std::string far = "<esi:include src=\"/a\">" + std::string(9000, 'z')
                      + "</esi:include>";
    CHECK_EQ(assemble(far), "AAA" + std::string(9000, 'z') + "</esi:include>");
}

int main()
{
    testPlain();
    testInclude();
    testOnError();
    testRemoveCommentWrapper();
    testMalformed();
    testNesting();
    testHuge();
    testBudgetAndSafety();
    testSlashAndContent();
    printf("esi tests: %d passed, %d failed\n", g_pass, g_fail);
    return g_fail ? 1 : 0;
}
