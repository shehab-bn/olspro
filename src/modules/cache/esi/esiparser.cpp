/*****************************************************************************
*    OLS PRO - ESI (Edge Side Includes) parser / assembler for LSCache.      *
*    GPLv3, see GPL.txt                                                      *
*****************************************************************************/
#include "esiparser.h"

#include <cstring>

namespace esi
{

static const std::string_view s_esiOpen("<esi:");
static const std::string_view s_cmtOpen("<!--esi");
static const std::string_view s_cmtClose("-->");
static const std::string_view s_removeClose("</esi:remove>");
static const std::string_view s_commentClose("</esi:comment>");
static const std::string_view s_includeClose("</esi:include>");
static const size_t npos = std::string_view::npos;

static inline bool isSpace(char c)
{
    return c == ' ' || c == '\t' || c == '\r' || c == '\n';
}

static inline bool startsWith(std::string_view s, size_t pos,
                              std::string_view pfx)
{
    return pos <= s.size() && s.size() - pos >= pfx.size()
           && memcmp(s.data() + pos, pfx.data(), pfx.size()) == 0;
}

bool containsEsi(std::string_view body) noexcept
{
    return body.find(s_esiOpen) != npos || body.find(s_cmtOpen) != npos;
}

bool isSafeSrc(std::string_view s) noexcept
{
    if (s.empty() || s[0] != '/')
        return false;                   // scheme, authority or relative
    if (s.size() > 1 && (s[1] == '/' || s[1] == '\\'))
        return false;                   // "//host" / "/\host"
    for (unsigned char c : s)
        if (c <= 0x20 || c == 0x7f)
            return false;               // CR/LF/space/controls
    return true;
}

// Decode the five predefined XML entities; anything else is kept verbatim.
static std::string decodeEntities(std::string_view v)
{
    std::string out;
    out.reserve(v.size());
    for (size_t i = 0; i < v.size(); ++i)
    {
        if (v[i] == '&')
        {
            static const struct { const char *e; size_t n; char c; } ents[] =
            {
                { "&amp;", 5, '&' }, { "&lt;", 4, '<' }, { "&gt;", 4, '>' },
                { "&quot;", 6, '"' }, { "&apos;", 6, '\'' },
            };
            bool hit = false;
            for (const auto &e : ents)
            {
                if (startsWith(v, i, std::string_view(e.e, e.n)))
                {
                    out += e.c;
                    i += e.n - 1;
                    hit = true;
                    break;
                }
            }
            if (hit)
                continue;
        }
        out += v[i];
    }
    return out;
}

namespace
{

struct Tag
{
    size_t  end = 0;            // index one past '>'
    bool    selfClosing = false;
    std::string_view attrs;     // raw attribute region
};

// Receives fragments in document order. Setting 'stop' aborts the parse.
struct Sink
{
    bool    stop = false;
    bool    hasEsi = false;
    virtual ~Sink() {}
    virtual void literal(std::string_view text) = 0;
    virtual void include(Fragment &fr) = 0;
};

// "First occurrence of needle at or after 'from'" cache for one window.
// Valid for any later query with from in [m.from, m.at], so with monotonic
// 'from' every search range is disjoint and the total cost is O(window).
struct Memo
{
    size_t  from = npos;
    size_t  at = npos;
};

class Parser
{
public:
    // Parses [begin, end) of body. Each instance is run() exactly once, so
    // the memos below are valid for its whole lifetime.
    Parser(std::string_view body, size_t begin, size_t end,
           const Limits &lim, Sink &sink, bool nested)
        : m_win(body.substr(0, end)), m_begin(begin), m_lim(lim)
        , m_sink(sink), m_nested(nested)
    {}

    void run();

private:
    size_t nextOf(std::string_view needle, size_t from, Memo &m) const
    {
        if (m.from != npos && from >= m.from && (m.at == npos || m.at >= from))
            return m.at;
        m.from = from;
        m.at = m_win.find(needle, from);
        return m.at;
    }

    bool scanTag(size_t nameEnd, Tag &tag) const;
    size_t skipIncludeBody(size_t after);
    static std::string_view getAttr(std::string_view attrs,
                                    std::string_view name, bool &found);

    void flush(size_t upto)
    {
        if (m_litStart != npos && upto > m_litStart)
            m_sink.literal(m_win.substr(m_litStart, upto - m_litStart));
        m_litStart = npos;
    }

    std::string_view    m_win;          // body truncated at window end
    size_t              m_begin;
    const Limits       &m_lim;
    Sink               &m_sink;
    bool                m_nested;       // inside <!--esi ... -->
    size_t              m_litStart = npos;
    Memo                m_cmtClose;
    Memo                m_removeClose;
    Memo                m_commentClose;
    Memo                m_includeClose;
    Memo                m_esiOpen;
};

// Scan an ESI start tag from just after its name to the closing '>',
// honoring single/double quotes. Bounded by maxTagLen. A '/' right before
// '>' only self-closes when it follows the name, whitespace or a closing
// quote, so an unquoted src=/blog/ keeps its trailing slash.
bool Parser::scanTag(size_t nameEnd, Tag &tag) const
{
    size_t limit = m_win.size();
    if (limit - nameEnd > m_lim.maxTagLen)
        limit = nameEnd + m_lim.maxTagLen;
    char quote = 0;
    for (size_t i = nameEnd; i < limit; ++i)
    {
        char c = m_win[i];
        if (quote)
        {
            if (c == quote)
                quote = 0;
            continue;
        }
        if (c == '"' || c == '\'')
            quote = c;
        else if (c == '<')
            return false;           // '<' inside a tag: malformed
        else if (c == '>')
        {
            size_t attrEnd = i;
            bool slash = (i > nameEnd && m_win[i - 1] == '/');
            if (slash)
            {
                // Outside quotes here, so a quote at i-2 closed a value.
                char pc = (i - 1 > nameEnd) ? m_win[i - 2] : ' ';
                slash = isSpace(pc) || pc == '"' || pc == '\'';
            }
            tag.selfClosing = slash;
            if (slash)
                --attrEnd;
            tag.attrs = m_win.substr(nameEnd, attrEnd - nameEnd);
            tag.end = i + 1;
            return true;
        }
    }
    return false;
}

// <esi:include ...>content</esi:include>: drop the content when the close
// tag is within maxTagLen and no other ESI element starts before it.
// Otherwise treat the include as empty and leave what follows alone.
size_t Parser::skipIncludeBody(size_t after)
{
    size_t q = nextOf(s_includeClose, after, m_includeClose);
    if (q == npos || q - after > m_lim.maxTagLen)
        return after;
    size_t e = nextOf(s_esiOpen, after, m_esiOpen);
    if (e != npos && e < q)
        return after;
    return q + s_includeClose.size();
}

// Attribute lookup: name="v" | name='v' | name=v. Names are case-sensitive
// (ESI is XML). Returns raw (undecoded) value.
std::string_view Parser::getAttr(std::string_view a, std::string_view name,
                                 bool &found)
{
    found = false;
    size_t i = 0, n = a.size();
    while (i < n)
    {
        while (i < n && isSpace(a[i]))
            ++i;
        size_t ns = i;
        while (i < n && !isSpace(a[i]) && a[i] != '=')
            ++i;
        std::string_view an = a.substr(ns, i - ns);
        while (i < n && isSpace(a[i]))
            ++i;
        std::string_view val;
        if (i < n && a[i] == '=')
        {
            ++i;
            while (i < n && isSpace(a[i]))
                ++i;
            if (i < n && (a[i] == '"' || a[i] == '\''))
            {
                char q = a[i++];
                size_t vs = i;
                while (i < n && a[i] != q)
                    ++i;
                val = a.substr(vs, i - vs);
                if (i < n)
                    ++i;
            }
            else
            {
                size_t vs = i;
                while (i < n && !isSpace(a[i]))
                    ++i;
                val = a.substr(vs, i - vs);
            }
        }
        if (an.empty())
        {
            if (i < n)
                ++i;                // skip stray char, guarantee progress
            continue;
        }
        if (an == name)
        {
            found = true;
            return val;
        }
    }
    return std::string_view();
}

void Parser::run()
{
    const size_t end = m_win.size();
    size_t p = m_begin;
    m_litStart = m_begin;
    while (p < end)
    {
        if (m_sink.stop)
            return;
        const void *lt = memchr(m_win.data() + p, '<', end - p);
        if (!lt)
            break;
        p = (const char *)lt - m_win.data();

        if (startsWith(m_win, p, s_cmtOpen))
        {
            size_t inner = p + s_cmtOpen.size();
            // A nested window ends at the first "-->", so a nested <!--esi
            // can never be terminated: literal without searching.
            size_t close = m_nested ? npos
                           : nextOf(s_cmtClose, inner, m_cmtClose);
            if (close == npos)
            {
                p = inner;          // unterminated: literal
                continue;
            }
            flush(p);
            m_sink.hasEsi = true;
            Parser sub(m_win, inner, close, m_lim, m_sink, true);
            sub.run();
            if (m_sink.stop)
                return;
            p = m_litStart = close + s_cmtClose.size();
            continue;
        }

        if (!startsWith(m_win, p, s_esiOpen))
        {
            ++p;
            continue;
        }

        size_t ns = p + s_esiOpen.size();
        size_t ne = ns;
        while (ne < end && m_win[ne] >= 'a' && m_win[ne] <= 'z')
            ++ne;
        std::string_view name = m_win.substr(ns, ne - ns);
        if (ne >= end || !(isSpace(m_win[ne]) || m_win[ne] == '/'
                           || m_win[ne] == '>'))
        {
            p = ns;                 // e.g. "<esi:includes" or truncated
            continue;
        }

        Tag tag;
        if (name == "include")
        {
            bool hasSrc = false, hasAlt = false, hasOe = false;
            if (!scanTag(ne, tag))
            {
                p = ns;
                continue;
            }
            std::string_view src = getAttr(tag.attrs, "src", hasSrc);
            if (!hasSrc || src.empty())
            {
                p = tag.end;        // include without src: keep literal
                continue;
            }
            std::string_view alt = getAttr(tag.attrs, "alt", hasAlt);
            std::string_view oe = getAttr(tag.attrs, "onerror", hasOe);
            size_t after = tag.selfClosing ? tag.end
                           : skipIncludeBody(tag.end);
            flush(p);
            if (m_sink.stop)
                return;
            Fragment fr;
            fr.kind = Fragment::INCLUDE;
            fr.text = m_win.substr(p, after - p);
            fr.src = decodeEntities(src);
            if (!isSafeSrc(fr.src))
                fr.src.clear();     // rejected: counts as a failed fetch
            if (hasAlt && !alt.empty())
            {
                fr.alt = decodeEntities(alt);
                if (!isSafeSrc(fr.alt))
                    fr.alt.clear();
            }
            fr.onErrorContinue = hasOe && oe == "continue";
            m_sink.hasEsi = true;
            m_sink.include(fr);
            p = m_litStart = after;
            continue;
        }
        if (name == "remove")
        {
            if (!scanTag(ne, tag) || tag.selfClosing)
            {
                if (tag.end && tag.selfClosing)
                {
                    flush(p);       // <esi:remove/>: empty, drop it
                    m_sink.hasEsi = true;
                    m_litStart = p = tag.end;
                    continue;
                }
                p = ns;
                continue;
            }
            size_t close = nextOf(s_removeClose, tag.end, m_removeClose);
            if (close == npos)
            {
                p = ns;             // unterminated: literal
                continue;
            }
            flush(p);
            m_sink.hasEsi = true;
            m_litStart = p = close + s_removeClose.size();
            continue;
        }
        if (name == "comment")
        {
            if (!scanTag(ne, tag))
            {
                p = ns;
                continue;
            }
            size_t after = tag.end;
            if (!tag.selfClosing)
            {
                size_t close = nextOf(s_commentClose, tag.end,
                                      m_commentClose);
                if (close == npos)
                {
                    p = ns;
                    continue;
                }
                after = close + s_commentClose.size();
            }
            flush(p);
            m_sink.hasEsi = true;
            m_litStart = p = after;
            continue;
        }
        // Unsupported ESI element (try/choose/vars/inline...): literal.
        p = ns;
    }
    if (!m_sink.stop)
        flush(end);
}

// parse(): collect into a vector, capping materialised includes.
struct VecSink : Sink
{
    ParseResult    &res;
    size_t          cap;

    VecSink(ParseResult &r, size_t c) : res(r), cap(c) {}

    void literal(std::string_view t) override
    {
        if (t.empty())
            return;
        std::vector<Fragment> &f = res.frags;
        // Coalesce with a directly adjacent previous literal.
        if (!f.empty() && f.back().kind == Fragment::LITERAL
            && f.back().text.data() + f.back().text.size() == t.data())
        {
            f.back().text = std::string_view(f.back().text.data(),
                                             f.back().text.size() + t.size());
            return;
        }
        Fragment fr;
        fr.kind = Fragment::LITERAL;
        fr.text = t;
        f.push_back(std::move(fr));
    }

    void include(Fragment &fr) override
    {
        if (res.includes >= cap)
        {
            res.truncated = true;
            literal(fr.text);
            return;
        }
        res.frags.push_back(std::move(fr));
        ++res.includes;
    }
};

enum RunRc
{
    RUN_OK,
    RUN_INCLUDE_FAIL,           // an include without onerror=continue failed
    RUN_FATAL                   // limits breached; out.ok already false
};

struct Assembler
{
    const Fetcher  &fetch;
    const Limits   &lim;
    AssembleResult &out;
    size_t          attempts = 0;
    size_t          parsed = 0;     // invariant: parsed <= lim.maxParseBytes
    std::string     firstFail;

    Assembler(const Fetcher &f, const Limits &l, AssembleResult &o)
        : fetch(f), lim(l), out(o)
    {}

    RunRc fatal(const char *why)
    {
        out.ok = false;
        if (out.error.empty())
            out.error = why;
        return RUN_FATAL;
    }

    // Try one URL: fetch and recursively assemble into out.body. A nested
    // include failure makes this URL fail (body rolled back) so the parent's
    // alt / onerror rules apply.
    RunRc tryOne(const std::string &url, size_t depth, bool &ok)
    {
        ok = false;
        if (url.empty()                 // rejected by isSafeSrc()
            || depth >= lim.maxDepth || attempts >= lim.maxIncludes)
        {
            ++out.failed;
            return RUN_OK;
        }
        ++attempts;
        std::optional<std::string> got = fetch(url);
        if (!got)
        {
            ++out.failed;
            return RUN_OK;
        }
        ++out.fetched;
        size_t mark = out.body.size();
        RunRc rc = run(*got, depth + 1);
        if (rc == RUN_FATAL)
            return rc;
        if (rc == RUN_INCLUDE_FAIL)
        {
            out.body.resize(mark);
            return RUN_OK;
        }
        ok = true;
        return RUN_OK;
    }

    RunRc onInclude(const Fragment &f, size_t depth)
    {
        bool ok = false;
        if (tryOne(f.src, depth, ok) == RUN_FATAL)
            return RUN_FATAL;
        if (!ok && !f.alt.empty() && tryOne(f.alt, depth, ok) == RUN_FATAL)
            return RUN_FATAL;
        if (!ok && !f.onErrorContinue)
        {
            // outermost failure is reported (inner ones are overwritten)
            firstFail = f.src.empty() ? std::string("(unsafe src rejected)")
                                      : f.src;
            return RUN_INCLUDE_FAIL;
        }
        return RUN_OK;
    }

    RunRc run(std::string_view body, size_t depth);
};

// resolve(): act on each fragment as it is parsed, nothing materialised.
struct AsmSink : Sink
{
    Assembler  &a;
    size_t      depth;
    RunRc       rc = RUN_OK;

    AsmSink(Assembler &as, size_t d) : a(as), depth(d) {}

    void literal(std::string_view t) override
    {
        if (stop)
            return;
        if (t.size() > a.lim.maxOutput - a.out.body.size())
        {
            rc = a.fatal("output exceeds maxOutput");
            stop = true;
            return;
        }
        a.out.body.append(t.data(), t.size());
    }

    void include(Fragment &fr) override
    {
        if (stop)
            return;
        RunRc r = a.onInclude(fr, depth);
        if (r != RUN_OK)
        {
            rc = r;
            stop = true;
        }
    }
};

RunRc Assembler::run(std::string_view body, size_t depth)
{
    if (body.size() > lim.maxParseBytes - parsed)
        return fatal("parse budget exceeds maxParseBytes");
    parsed += body.size();
    AsmSink sink(*this, depth);
    if (!containsEsi(body))
        sink.literal(body);
    else
    {
        Parser p(body, 0, body.size(), lim, sink, false);
        p.run();
    }
    return sink.rc;
}

} // namespace

ParseResult parse(std::string_view body, const Limits &lim) noexcept
{
    ParseResult res;
    try
    {
        if (body.empty())
            return res;
        if (!containsEsi(body))
        {
            Fragment fr;
            fr.text = body;
            res.frags.push_back(std::move(fr));
            return res;
        }
        VecSink sink(res, lim.maxIncludes);
        Parser p(body, 0, body.size(), lim, sink, false);
        p.run();
        res.hasEsi = sink.hasEsi;
    }
    catch (...)
    {
        res.frags.clear();
        res.includes = 0;
        res.ok = false;
    }
    return res;
}

AssembleResult resolve(std::string_view body, const Fetcher &fetch,
                       const Limits &lim) noexcept
{
    AssembleResult out;
    try
    {
        out.body.reserve(body.size() < lim.maxOutput ? body.size()
                                                     : lim.maxOutput);
        Assembler a(fetch, lim, out);
        RunRc rc = a.run(body, 0);
        if (rc == RUN_INCLUDE_FAIL)
        {
            out.ok = false;
            out.error = "include failed: " + a.firstFail;
        }
    }
    catch (...)
    {
        out.ok = false;
        try
        {
            out.error = "exception during ESI processing";
        }
        catch (...)
        {}
    }
    if (!out.ok)
        std::string().swap(out.body);   // never served; free it now
    return out;
}

} // namespace esi
