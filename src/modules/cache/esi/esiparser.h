/*****************************************************************************
*    OLS PRO - ESI (Edge Side Includes) parser / assembler for LSCache.      *
*    GPLv3, see GPL.txt                                                      *
*****************************************************************************/
#ifndef OLSPRO_ESIPARSER_H
#define OLSPRO_ESIPARSER_H

#include <cstddef>
#include <functional>
#include <optional>
#include <string>
#include <string_view>
#include <vector>

/*
 * std-only C++17. No OLS headers, no allocation per literal byte: literal
 * fragments are string_views into the caller's buffer (for example an
 * mmap()ed cache entry), so the buffer must outlive the ParseResult.
 *
 * Supported (ESI 1.0 subset used by LiteSpeed Cache / WordPress plugins):
 *   <esi:include src="..." [alt="..."] [onerror="continue"] />
 *   <esi:include src="..."></esi:include>  (content up to the close tag,
 *                                          within maxTagLen, is dropped)
 *   <esi:remove> ... </esi:remove>         (dropped)
 *   <esi:comment text="..."/>               (dropped)
 *   <!--esi ... -->                        (wrapper stripped, body parsed)
 * Anything else, and anything malformed or unterminated, is kept as literal
 * text. Parsing is linear in the input size (every closing-tag search is
 * memoised per window), never reads out of bounds, and neither parse() nor
 * resolve() lets an exception escape.
 */
namespace esi
{

struct Fragment
{
    enum Kind
    {
        LITERAL,
        INCLUDE
    };
    Kind                kind = LITERAL;
    std::string_view    text;               // view into input: LITERAL text,
                                            // or the whole INCLUDE construct
    std::string         src;                // INCLUDE: entity-decoded; empty
                                            // = rejected by isSafeSrc()
    std::string         alt;                // INCLUDE: may be empty
    bool                onErrorContinue = false;
};

struct Limits
{
    size_t  maxDepth        = 5;            // nested include levels
    size_t  maxIncludes     = 256;          // total fetches per resolve();
                                            // also caps INCLUDE frags in parse()
    size_t  maxOutput       = 16u << 20;    // assembled body cap (fatal)
    size_t  maxParseBytes   = 32u << 20;    // total bytes parsed per resolve()
                                            // (top body + every fragment, fatal)
    size_t  maxTagLen       = 8192;         // longest <esi:...> start tag
};
// Callers should derive maxOutput / maxParseBytes from the cache's
// maxObjSize (default 10 MB) rather than relying on these defaults.

struct ParseResult
{
    std::vector<Fragment>   frags;
    size_t                  includes = 0;   // INCLUDE fragments in frags
    bool                    hasEsi = false; // any ESI construct consumed
    bool                    truncated = false; // > maxIncludes includes: the
                                            // excess was emitted as literal
    bool                    ok = true;      // false: out of memory, frags empty
};

// Cheap pre-check: true if the buffer contains "<esi:" or "<!--esi".
bool containsEsi(std::string_view body) noexcept;

// Include target policy, enforced by the parser on src and alt: host-relative
// path only ('/' first, not "//" or "/\"), no scheme/authority, no bytes
// <= 0x20 or 0x7f (blocks CR/LF header injection and request-line splitting).
// A rejected src/alt is treated as a failed fetch (alt / onerror apply).
bool isSafeSrc(std::string_view src) noexcept;

// Inspection API. Materialises at most lim.maxIncludes INCLUDE fragments.
ParseResult parse(std::string_view body, const Limits &lim = Limits()) noexcept;

/*
 * src -> body, or std::nullopt on failure / miss.
 *
 * Called synchronously from resolve(), i.e. from the worker's event loop
 * once wired into handlerProcess(). It MUST NOT block: the only viable
 * implementation today is a local cache lookup (src resolved against the
 * current request's vhost, never a host taken from src) that returns
 * std::nullopt on a miss so alt / onerror apply. OLS has no usable
 * sub-request API (new_subreq & co are commented out in include/ls.h), so a
 * backend fetch needs a resumable resolve() first; see README.md.
 * An exception thrown by the fetcher makes resolve() return ok=false.
 */
using Fetcher = std::function<std::optional<std::string>(const std::string &src)>;

struct AssembleResult
{
    bool        ok = true;      // false: fatal ESI error, 'body' is cleared;
                                // caller must answer 500 (see README.md)
    std::string body;
    std::string error;          // reason when !ok
    size_t      fetched = 0;    // successful fetches
    size_t      failed = 0;     // failed fetch attempts (src or alt)
};

/*
 * Assemble the final body. For each include: try src, then alt; fetched
 * bodies are themselves ESI-processed up to lim.maxDepth. If both fail:
 * onerror="continue" -> include silently removed; otherwise -> fatal
 * (ok=false), per ESI 1.0. Depth / include-count overruns and unsafe
 * src/alt count as a fetch failure for that include. Exceeding maxOutput or
 * maxParseBytes is fatal. Streams fragments: memory is O(output + depth).
 */
AssembleResult resolve(std::string_view body, const Fetcher &fetch,
                       const Limits &lim = Limits()) noexcept;

} // namespace esi

#endif // OLSPRO_ESIPARSER_H
