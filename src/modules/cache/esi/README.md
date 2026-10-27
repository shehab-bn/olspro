# OLS PRO - ESI foundation for LSCache

Status: **parser + assembler only, not wired into the cache module yet.**
Hardened after the 10-27 review (linear parsing, parse budget, src policy,
noexcept, include-count cap).
`src/modules/cache/cachectrl.cpp` already parses the `esi=on|off` token of
`X-LiteSpeed-Cache-Control` into `CacheCtrl::esi_on`, but nothing consumes it.
This directory provides the missing processor; hooking it up is listed below.

## Files

| File | What |
|---|---|
| `esiparser.h/.cpp` | std-only C++17. `esi::parse()` -> ordered fragments, `esi::resolve()` -> assembled body |
| `tests/test_esi.cpp`, `tests/run.sh` | 125 checks: normal, attribute quoting/entities, onerror/alt, malformed, nesting/loops, limits, src policy, exceptions, 8 MB + 200k-include + pathological / amplification inputs with timing bounds |

Run: `sh src/modules/cache/esi/tests/run.sh` (add `ESI_SANITIZE=1` for ASan/UBSan, `CXX=g++` to pick the compiler).

## Behaviour

- Supported: `<esi:include src alt onerror="continue"/>` (self-closing or with
  `</esi:include>`; content before the close tag is dropped when the close is
  within `maxTagLen` and no other ESI element starts first, otherwise the
  include is treated as empty), `<esi:remove>..</esi:remove>`,
  `<esi:comment .../>`, `<!--esi ... -->` (wrapper stripped, contents parsed).
- A `/` before `>` only self-closes after the element name, whitespace or a
  closing quote, so unquoted `src=/blog/>` keeps its trailing slash.
- Element and attribute names are case-sensitive (ESI is XML). Attribute
  values may be `"..."`, `'...'` or unquoted; the 5 XML entities are decoded
  (`&amp;` in query strings is the common case).
- Malformed or unterminated constructs (missing `>`, unclosed quote, unclosed
  `<esi:remove>` / `<!--esi`, `<` inside a tag, include without `src`) and
  unsupported elements (`esi:try`, `esi:choose`, `esi:vars`, `esi:inline`)
  are emitted **as literal text**. The parser never throws on input.
- Literal fragments are `string_view`s into the input (mmap-friendly, no copy).
  Every closing-tag search goes through a per-window "next occurrence" memo
  (each `Parser` instance runs exactly once over a fixed window), and a
  `<!--esi` nested inside a `<!--esi ... -->` window is literal without
  searching (that window already ends at the first `-->`). Hostile input is
  linear: 1 MB of unterminated openers inside one `<!--esi ... -->` parses in
  a few ms (was 25-75 s before the 10-27 fix).
- `src` / `alt` policy (`esi::isSafeSrc`, enforced by the parser): host-relative
  path only (`/` first, not `//` or `/\`, no scheme/authority) and no bytes
  `<= 0x20` or `0x7f` (CR/LF header injection, request-line splitting). A
  rejected value counts as a failed fetch, so `alt` / `onerror` apply.
- `parse()` and `resolve()` are `noexcept`: `bad_alloc` or a throwing fetcher
  yields `ok=false` instead of `std::terminate` in the worker.
- `resolve()`: try `src`, then `alt`. Fetched bodies are ESI-processed
  recursively. If both fail: `onerror="continue"` drops the include, otherwise
  the include fails; a failure inside a nested fragment rolls that fragment
  back so the parent's `alt`/`onerror` applies. A failure that reaches the top
  returns `ok=false` and the caller must not serve `body`.
- Limits (`esi::Limits`): `maxDepth` 5, `maxIncludes` 256 fetches per
  response, `maxOutput` 16 MB (fatal), `maxParseBytes` 32 MB of total parsed
  input per `resolve()` including the top body (fatal; stops a fragment that
  includes itself with `onerror="continue"` from burning CPU with empty
  output, worst case ~0.3 s), `maxTagLen` 8 KB. Depth/count overruns count as
  fetch failures, so self-including loops terminate. Derive `maxOutput` /
  `maxParseBytes` from the cache's `maxObjSize` (default 10 MB) when wiring.
- `resolve()` streams: fragments are handled as they are parsed, so memory is
  O(output + depth). `parse()` (inspection only) materialises at most
  `maxIncludes` INCLUDE fragments; the excess is emitted as literal and
  `ParseResult::truncated` is set.

## Not done (follow-ups)

1. **Hook-up in `cache.cpp`** (see next section).
2. Chunk-boundary streaming: the parser works on one contiguous buffer. That
   is fine for the cache-hit path (entry is mmap()ed), not for in-flight
   `LSI_HKPT_RECV_RESP_BODY` filtering.
3. ESI variables (`$(HTTP_COOKIE{...})`, `$(QUERY_STRING)`), `esi:try`,
   `esi:choose`, `esi:vars`, `esi:inline`.
4. Fetcher implementation: cache lookup only (see C). Backend fragments
   need a resumable `resolve()` first.
5. CMake: add `esi/esiparser.cpp` to the `cache` target sources in
   `src/modules/cache/CMakeLists.txt` (not edited here, owned elsewhere).

## Hook-up plan for `src/modules/cache/cache.cpp`

Line numbers are from the tree on 2026-10-27.

**A. Store-side flag (miss path).** `createEntry()` (registered on
`LSI_HKPT_RCVD_RESP_HEADER`, ~L1959) already has the parsed `CacheCtrl`
(`myData->cacheCtrl`). When `esi_on` is set, record it in the entry header
(`CeHeader` flags, `ceheader.h`) so the hit path knows the stored body
contains ESI markup. The body is written unchanged by `cacheTofile()` /
`cacheTofileFilter()` (`LSI_HKPT_RCVD_RESP_BODY` / `LSI_HKPT_SEND_RESP_BODY`,
~L2501-2600). Store raw ESI, never the assembled output, because fragments
have their own TTL / privacy.

Also on the miss path the origin response itself must be assembled before it
reaches the client: add a body filter (or buffer until `endCache()` on
`LSI_HKPT_HTTP_END`) that runs `esi::resolve()` when `esi_on` is set. This is
where follow-up 2 (streaming) matters.

**B. Hit path (main win).** `handlerProcess()` (~L3606, the module's request
handler registered via `register_req_handler` in `checkAssignHandler()`)
serves a hit at ~L3889-3897:

```cpp
g_api->set_resp_content_length(session, length);
if (g_api->send_file2(session, fd, part2offset, length) == 0)
    g_api->end_resp(session);
```

For ESI-flagged entries replace this with:

1. Map the body. `part2offset` is generally not page-aligned, so
   `mmap(fd, offset=part2offset)` fails with `EINVAL`. Map from offset 0 with
   length `part2offset + length` (or from `part2offset` rounded down to the
   page size), build the `string_view` from `base + part2offset`, and
   `munmap()` with the same length. The existing `pBuffOrg` mapping of
   `[0, part2offset)` can simply be extended to cover the body.
2. If the entry is gzip/br-compressed (`compressType != LSI_NO_COMPRESS`),
   either always store ESI entries uncompressed (simplest: skip
   `toggleGzipState()` for them) or inflate first.
3. Run `esi::resolve(view, fetcher)` **before** any stored header or status
   is applied (`set_resp_header2` / `set_status_code`, ~L3820-3870). On `ok`
   apply the stored headers, then `set_resp_content_length(session,
   out.body.size())`, `append_resp_body(...)`, `end_resp(session)`. On `!ok`
   answer a plain 500 without the cached headers. There is no "fall through
   to the backend" here: `checkAssignHandler()` has already called
   `register_req_handler` (cache.cpp ~L2957/3044), and nothing in this flow
   hands the request back. If a backend fallback is wanted, the hit/bypass
   decision (including ESI resolution) must move before
   `register_req_handler`.
4. Let the server's dynamic compression handle the assembled body
   (`set_resp_buffer_compress_method`), and drop `Content-Length` /
   `ETag` from the stored headers for ESI entries since they no longer match.

**C. Fetcher.** `esi::Fetcher` is a synchronous `std::function` called
inline from `resolve()`, which runs inside `handlerProcess()` on the worker's
event loop. Anything that blocks (a PHP/backend fetch, a slow disk) stalls
every connection on that worker, so the **only viable fetcher today is a
local cache lookup**:

- Resolve `src` against the **current request's vhost** and look it up as a
  cache key in the same `CacheManager` (public, then private store); never
  take a host from `src` (the parser already rejects scheme/authority, `//`,
  control bytes and spaces, but the fetcher must not widen that).
- On a miss or a stale/expired entry return `std::nullopt` immediately so
  `alt` / `onerror` apply. Do not wait for, or trigger, a backend fetch.
- Even this does file I/O on the loop; keep fragment entries small and
  prefer already-mmapped or page-cached entries.

Backend fragments (fetch on miss, cache under the fragment's own
`X-LiteSpeed-Cache-Control`) are **not buildable on this API**: the LSIAPI
sub-request entry points (`new_subreq`, `exec_subreq`, `close_subreq`,
`include_subreq_resp`) are commented out in `include/ls.h` (~L3861-3867).
That needs a redesign first: a resumable `resolve()` that returns
`NEED_FETCH(src)` and resumes from saved parser state once an async fetch
completes. Do not plan on the commented-out sub-request API.

**D. Purge/tags.** Fragments carry their own `X-LiteSpeed-Tag`; the parent
page must not inherit them. No change needed in the purge code as long as the
parent stores raw ESI (step A).
