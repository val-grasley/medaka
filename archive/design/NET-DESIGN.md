# NET-DESIGN.md — Medaka networking (decision-ready)

**Status:** IMPLEMENTED — `9100df2e`, 2026-07-01. Shipped as `stdlib/net.mdk` (native,
build-path only); see STDLIB.md Module 19 for the current capability summary and
`test/diff_net.sh` for the gate. This doc's design (extern set, effect wiring,
staging plan below) is the historical record of how it was built — Supersedes/deepens
`P1-STDLIB-DESIGN.md` §5 (the first-cut networking section, also landed).

**Scope of this doc:** the extern set, effect wiring, resource-lifetime story,
C-runtime sketch, interpreter/wasm posture, `stdlib/net.mdk` API, a staging plan,
a testability plan, and the design forks that need a human decision.

**Verified facts this builds on (do not re-derive):**

1. `Net` is **already** a registered builtin effect label (`compiler/frontend/resolve.mdk`
   `builtInEffects`; `compiler/types/typecheck.mdk` `seedEffectDomains` registers
   `Net = PPrefix None`). The **`Product` refinement domain** (`Host(Prefix) ×
   Method(Set)`) is **implemented** (`WS-4-DESIGN.md`, status IMPLEMENTED
   2026-06-22). So networking needs **externs + C runtime + a stdlib module — NOT
   new effect infrastructure.**
2. The tree-walking interpreter (`medaka run`) is a deliberately **pure, FFI-free,
   deterministic oracle**. Verified: `readFile`/`statFile`/`runCommand`/`listDir`/
   `writeFile` are **absent** from `compiler/eval/eval.mdk`'s `primitives` list
   (`grep -c` = 0) → they are simply **unbound** under `run` (like the faked
   `pWallTimeSec`). **Net externs are likewise build-path only.**
3. **Native-only.** Raw BSD sockets don't exist on WasmGC. `net` is a gated
   native-only capability module.
4. **No catchable panics / no RAII / no `finally`.** Sockets are fd handles with no
   automatic cleanup → leak-safety is designed in the stdlib layer (a `withSocket`/
   `withConnection` bracket), not the language.
5. **Extern threading template = the file externs, verified end-to-end:**
   - `stdlib/runtime.mdk`: `extern readFile : String -> <FileRead "_"> Result String String`
     (note the **fmt-normalized quoted hole `"_"`**, and `Result String X` errors,
     `Array Int` bytes, tuples `(Int, String, String)`).
   - `runtime/medaka_rt.c`: `mdk_read_file` etc. — build `Result` via `mdk_ok(x)` /
     `mdk_err(mdk_str_cstr(strerror(errno)))`; string cell payload at `ptr + 24`;
     tuples `[MDK_TUPLE_TAG, e0, e1, …]`; tagged Int `(v<<1)|1`; Bool `True=3/False=1`;
     Float via `mdk_box_float`; `Array Int` as `[len, b0<<1|1, …]`.
   - `compiler/backend/llvm_preamble.mdk`: `"declare i64 @mdk_read_file(i64)"`.
   - `compiler/backend/llvm_emit.mdk`: `isFileExtern` name-set + a per-name
     `emitFileExtern` arm that `emitArgs` then `call i64 @mdk_<fn>(…)` returning
     `(reg, LTCon)`.
6. **Async** is a value-level cooperative monad (`stdlib/async.mdk`), **no
   `<Async>` effect**. v1 net is **blocking**; async is a noted follow-on.

---

## 1. Scope + comparison

### What "networking" spans (the axes)

| Axis | v1 recommendation |
|---|---|
| **TCP client** (connect/send/recv/close) | **YES** — the anchor use case |
| **TCP server** (bind/listen/accept) | **YES** — cheap (same extern family) *and it is what makes hermetic testing possible* (§8) |
| **DNS resolution** (`getaddrinfo`) | **YES** — connect-by-hostname needs it; expose `resolve` too |
| **UDP** (bind/sendTo/recvFrom) | **v1.5** — small, additive; deferred unless a consumer needs it |
| **Socket options** (SO_REUSEADDR, TCP_NODELAY) | **minimal** — set sane defaults in C; expose `setNoDelay`/`setReuseAddr` in v1.5 |
| **Timeouts** (SO_RCVTIMEO/SO_SNDTIMEO) | **v1** — one `setTimeout` extern; a blocking-only model *needs* timeouts to be usable |
| **TLS/HTTPS** | **NO** — pulls in crypto (P3); explicitly out of scope |
| **Non-blocking / select / epoll** | **NO (v1)** — the async-integration follow-on |

### Comparison against Go / Rust / Python / Zig

| | Go `net` | Rust `std::net` | Python `socket` | Zig `std.net` | **Medaka v1 (proposed)** |
|---|---|---|---|---|---|
| Model | blocking API over M:N goroutines | **blocking** (async is 3rd-party) | **blocking** (low-level BSD 1:1) | **blocking** | **blocking** |
| Client | `Dial("tcp", "host:port")` → `Conn` | `TcpStream::connect` | `socket()`+`connect()` | `tcpConnectToHost` (DNS+connect) | `connect host port` → `Socket` |
| Server | `Listen`→`Accept`→`Conn` | `TcpListener::bind`→`accept` | `bind`+`listen`+`accept` | `Address.listen`→`accept` | `listen host port`→`accept` |
| Conn abstraction | `Conn` (io.Reader/Writer) | `TcpStream` (Read/Write) | raw socket object | `Stream` (reader/writer) | abstract `Connection` |
| DNS | integrated in `Dial` | via `ToSocketAddrs` | `getaddrinfo` | in `tcpConnectToHost` | explicit `resolve` + implicit in `connect` |
| UDP | `net.UDPConn` | `UdpSocket` | same socket API | present | v1.5 |
| Errors | `error` return | `io::Result` | exceptions | `!` error unions | **`Result String _`** |
| Cleanup | `defer conn.Close()` | **RAII `Drop`** | GC + `with` | `defer`/manual | **`withConnection` bracket** (no RAII) |
| TLS/HTTP | `crypto/tls`, `net/http` in-core | 3rd-party | `ssl`, `http.client` | evolving | **out of scope** |

**Takeaways that shaped the design:**

- **Everyone's std baseline is blocking.** Go *looks* async but its `net` API is
  blocking calls multiplexed by the runtime; Rust/Python/Zig std are frankly
  blocking with opt-in non-blocking. A blocking v1 is the correct, well-precedented
  baseline — it is not a compromise.
- **The `Conn`/`Stream`/`TcpStream` abstraction is universal** — every language
  hands back an opaque bidirectional handle, not a raw fd. Medaka mirrors this with
  an **abstract `Connection`** (a newtype the user cannot fabricate).
- **Cleanup is the one axis where Medaka is structurally different:** Go has
  `defer`, Rust has `Drop`, Python has GC + `with`. Medaka has **none of these** —
  hence `withConnection` is a *required*, first-class part of the design, not an
  afterthought (§4).
- **Recommended v1 scope: TCP client + TCP server + DNS resolve, blocking, with
  read/write timeouts, plaintext only.** Server is *in* v1 (not "next") precisely
  because it is nearly free and it unlocks the single-process loopback self-test
  (§8). UDP, socket-options beyond timeout, non-blocking/async, and TLS/HTTP are
  explicitly later.

Sources: [Go net](https://pkg.go.dev/net) · [Rust std::net](https://doc.rust-lang.org/std/net/index.html) · [Python socket](https://docs.python.org/3/library/socket.html) · [Zig std.net (issue #7194 plan)](https://github.com/ziglang/zig/issues/7194)

---

## 2. The extern set (v1)

All externs live in `stdlib/runtime.mdk`, carry the `<Net "_">` effect
(fmt-normalized quoted hole, exactly like `<FileRead "_">`), return
`Result String _`, and traffic **raw tagged `Int` handles** at the extern boundary
(the abstract `Socket`/`Connection`/`Listener` newtypes are a *stdlib* concern —
§7 — so `runtime.mdk` stays extern-only and needs no type in scope).

```medaka
-- DNS ---------------------------------------------------------------------
extern netResolve    : String -> <Net "_"> Result String (List String)
                        -- hostname -> list of numeric IP strings (getaddrinfo)

-- TCP client --------------------------------------------------------------
extern netTcpConnect : String -> Int -> <Net "_"> Result String Int
                        -- host, port -> connected fd (does DNS internally)

-- TCP server --------------------------------------------------------------
extern netTcpListen  : String -> Int -> <Net "_"> Result String Int
                        -- bind addr, port (0 = ephemeral) -> listening fd
extern netListenPort : Int -> <Net "_"> Result String Int
                        -- listening fd -> actual bound port (for port 0; enables self-test §8)
extern netTcpAccept  : Int -> <Net "_"> Result String Int
                        -- listening fd -> accepted connection fd (blocks)

-- Data transfer (fd is a connected/accepted socket) -----------------------
extern netSend       : Int -> Array Int -> <Net "_"> Result String Int
                        -- fd, bytes -> count actually written (may be < len)
extern netRecv       : Int -> Int -> <Net "_"> Result String (Array Int)
                        -- fd, maxBytes -> bytes read (empty Array = peer closed / EOF)

-- Lifecycle ---------------------------------------------------------------
extern netShutdown   : Int -> Int -> <Net "_"> Result String Unit
                        -- fd, how (0=read,1=write,2=both) -> shutdown(2)
extern netClose      : Int -> <Net "_"> Result String Unit
                        -- fd -> close(2); idempotent-safe in the C shim

-- Options -----------------------------------------------------------------
extern netSetTimeout : Int -> Int -> <Net "_"> Result String Unit
                        -- fd, milliseconds (0 = blocking/no timeout) -> SO_RCVTIMEO+SO_SNDTIMEO
```

**Deferred to v1.5 (same shape, same family):**

```medaka
extern netUdpBind    : String -> Int -> <Net "_"> Result String Int
extern netUdpSendTo  : Int -> String -> Int -> Array Int -> <Net "_"> Result String Int
extern netUdpRecvFrom: Int -> Int -> <Net "_"> Result String (Array Int, String, Int)
extern netSetNoDelay : Int -> Bool -> <Net "_"> Result String Unit   -- TCP_NODELAY
extern netSetReuse   : Int -> Bool -> <Net "_"> Result String Unit   -- SO_REUSEADDR
```

**Design notes on the extern set:**

- **12 externs in v1** (10 core + `netListenPort` + `netSetTimeout`). Count is close
  to P1's "~10 externs" estimate.
- **`netSend`/`netRecv` are honest about short I/O** — like every BSD `send`/`recv`,
  they return a *count*, not a guarantee. The full-write/read loop is a **pure
  Medaka helper** in `stdlib/net.mdk` (§7), not a C concern. This keeps the C shims
  thin (the runtime-language decision) and testable.
- **`Array Int` payload reuses the P1 `bytes` layer** — this is *why* `bytes` is
  sequenced before `net` in P1. String↔bytes conversion (`stringToUtf8Bytes` /
  `stringFromUtf8Bytes` already exist as externs) gives text helpers.
- **Renaming vs P1's first cut:** P1 used `tcpConnect`/`socketSend`/`dnsResolve`. I
  prefix everything `net*` for a clean `isNetExtern` name-set (§5 wasm gating) and
  extern-namespace hygiene. Cosmetic; not a fork.
- **`netListenPort` is new vs P1** and is load-bearing for testability (§8): binding
  to port `0` and reading the OS-assigned port makes the loopback fixture hermetic
  (no hard-coded port → no CI port collisions).

### Handle representation

**Extern boundary: raw tagged `Int` fd.** Simplest ABI (no new C cell type; reuses
the existing tagged-int encoding `(fd<<1)|1`).

**stdlib surface: abstract newtypes** `Socket`/`Listener`/`Connection` wrapping the
`Int`, with **unexported constructors** so user code cannot fabricate a fd, do
arithmetic on it, or pass a listening fd where a connected one is wanted. This is
the fd-as-Int-*inside* / abstract-*outside* split — it gets the ABI simplicity of
Int and the type-safety of Go's `Conn`. (**This is design fork F4 — §9.**)

---

## 3. Effect wiring — how `<Net>` refines

### The label and the hole

Every net extern's return type carries `<Net "_">`. The `"_"` is the WS-2/WS-3b
**hole**: a placeholder the typechecker fills by α-recovery from the call site.

- `seedEffectDomains` already registers `Net = PPrefix None` (⊤ = "any host").
- `normHole` normalizes `PPrefix (Some "_")` → `PPrefix None`, so an *unrecovered*
  hole degrades to ⊤ (unconstrained Net) — the sound over-approximation.
- **`holeFillParam`** (typecheck.mdk) recovers a `PPrefix (Some host)` from the
  **first argument's literal** when it is a string literal.

### Refinement behavior

```medaka
tcpConnect "api.example.com" 443   -- host is a string literal
  ⇒ row refines to  <Net "api.example.com">   (PPrefix (Some "api.example.com"))

let h = getUserHost ()             -- host is dynamic
tcpConnect h 443
  ⇒ hole cannot be recovered ⇒ stays <Net "_"> ⇒ normHole ⇒ PPrefix None (⊤)
  ⇒ manifest shows unconstrained Net  (honest: the compiler cannot bound a runtime host)
```

This mirrors `<FileRead "_">` exactly (a literal path refines; a dynamic path stays
⊤). **No compiler change is needed** — the recovery machinery is domain-generic and
already runs for `FileRead`/`FileWrite`/`Env`/`Exec`.

### Granularity: host-only Prefix in v1 (NOT Host×Method Product)

The **WS-4 `Product` domain (`Host × Method`)** exists, but its `Method` axis is
**HTTP-level** (GET/POST) — meaningless for *raw* TCP. For `net`, the
security-relevant axis is the **host** (which peers can this code reach), which the
`PPrefix` domain already captures. `Net` is in fact **currently seeded
`PPrefix None`** in `seedEffectDomains` (typecheck.mdk) — so host-only refinement is
already the default and needs **zero change**. **Recommendation: `net` keeps plain
`PPrefix` host refinement.** The `Product` domain is the right tool for a *future
`http` module* (implemented surface is capitalized axes:
`<Net Host="api.example.com/*" Method={GET,POST}>`), reached only by flipping the
`Net` seed to `PProduct []`, where `netTcpConnect` is the plumbing and `http` adds
the method axis. (Host×**Port** as a 2-axis Product is a
possible future refinement — **fork F5, §9** — but low-value for v1.)

### Tie to the capability manifest

Because `<Net "host">` flows into the effect row, `medaka manifest` emits it into
`[package.capabilities]` TOML (the WS-1c machinery, already shipped), and
`medaka check-policy --allow 'Net=api.example.com/*'` validates it via domain `dsub`
(WS-1b). Networking thus becomes a **compiler-verified capability manifest** for
free — a program that only ever calls `tcpConnect "api.example.com" …` has a
manifest pinned to that host; a program with a dynamic host advertises unconstrained
`Net` (which a strict platform policy can reject). See `CAPABILITY-EFFECTS.md`
("the handler is the host": the platform reads the row and grants exactly those
host imports).

---

## 4. Resource lifetime — leak-safety with no RAII, no catchable panics

**This is the hard part.** A socket is a fd with no destructor, no `finally`, no
`try`/`catch`. Two failure modes to design against:

1. **Error mid-use** — `netRecv` returns `Err` and the code returns early without
   closing → fd leak.
2. **Panic** — some *other* code panics while a socket is open.

### Key insight: the panic case is a non-problem

Medaka panics are **unrecoverable and terminate the process** (decided invariant).
When the process dies, the OS reclaims every fd. So a panic **cannot leak a fd
across program runs** — leak-safety only matters for the **`Result`-error path in a
long-running process** (e.g. a server accept-loop that errors per connection). This
is *narrower* than the RAII problem in exception-based languages, and it means the
whole leak story reduces to: **"always close on the `Result`-error path."** A bracket
combinator handles that completely, because the only non-local exit that could skip
the close (a panic) also ends the process.

### The blessed pattern: `withConnection` / `withListener` brackets

Pure-Medaka combinators in `stdlib/net.mdk`. They acquire, run the body, and
**close unconditionally** — closing on both the `Ok` and `Err` body result, then
returning the body's result. Because Medaka has no non-local return except panic
(fatal), "run the body then close" is airtight.

```medaka
-- acquire a connected socket, run body, always close, return body's Result
withConnection : String -> Int -> (Connection -> <Net> Result String a)
              -> <Net> Result String a
withConnection host port body =
  match connect host port
    Err e => Err e                       -- never opened; nothing to close
    Ok conn =>
      let r = body conn                  -- body may Ok or Err; no non-local exit
      let _ = close conn                 -- ALWAYS runs (close errors folded/ignored)
      r

-- server bracket: bind+listen, run body with the Listener, always close listener
withListener : String -> Int -> (Listener -> <Net> Result String a)
            -> <Net> Result String a
```

**Usage — early `Err` return still closes:**

```medaka
withConnection "api.example.com" 80 (\conn =>
  do
    _    <- sendLine conn "GET / HTTP/1.0\r\n\r\n"   -- if this Err's, `?`-style
    resp <- recvAll conn                             --   short-circuits the do,
    pure resp)                                       --   `let r = body`, then close.
```

Here `sendLine`/`recvAll` return `Result` and the `do`-block threads them
(monadic short-circuit on `Err`). Whatever the body produces — `Ok resp` or an
early `Err` — `withConnection` binds it to `r`, closes the socket, and returns `r`.
**No leak on any error path.** (The `do` desugars to `andThen`; the `Result` monad's
`andThen` short-circuits on `Err` — that is the "early return", and it returns *into*
the bracket, not out of it.)

### Accept-loop safety (server)

The dangerous long-running case is a server that accepts in a loop and errors per
connection. The pattern: each accepted connection is itself wrapped.

```medaka
serveLoop : Listener -> (Connection -> <Net> Result String Unit) -> <Net> Result String Unit
serveLoop lis handle =
  match accept lis
    Err e     => Err e                    -- listener-level error: propagate up
    Ok conn   =>
      let _ = (let r = handle conn in let _ = close conn in r)   -- per-conn bracket
      serveLoop lis handle                -- tail-recurse; one connection's Err
                                          --   does NOT leak (closed above) nor kill the loop
```

(A real server would log the per-connection `Err` rather than discard it; shown
minimal here.) The point: **the fd is closed before the next `accept`, regardless of
the handler's result.**

### Double-close and use-after-close

- `netClose` in C is written **idempotent-safe** (guards against closing an already
  invalid fd; returns `Ok Unit` on a benign double-close rather than an errno race).
- Use-after-close (calling `netSend` on a closed fd) returns `Err "Bad file
  descriptor"` from the kernel (`EBADF`) — surfaced as a normal `Result`, not a
  crash. This is *acceptable* (the type system does not track linearity; the
  runtime degrades gracefully). Documented, not prevented. (A linear-types story to
  *prevent* use-after-close is explicitly out of scope — noted as future.)

---

## 5. C-runtime sketch (`runtime/medaka_rt.c`)

Thin BSD-socket shims mirroring the file-extern ABI exactly. Blocking. Errors:
`errno → strerror → mdk_err(mdk_str_cstr(...))`.

```c
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>   /* TCP_NODELAY */
#include <netdb.h>         /* getaddrinfo */
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>

/* Tagged-Int fd ABI: fd is carried as (fd<<1)|1, exactly like every other Int. */
#define UNTAG(x)  ((int)((x) >> 1))
#define TAG(v)    ((((long long)(v)) << 1) | 1)

/* netTcpConnect : host -> port -> Result String Int  (fd)
 * getaddrinfo(host, port) then connect the first address that works. */
long long mdk_net_tcp_connect(long long host_cell, long long port_tagged) {
  const char *host = (const char *)host_cell + 24;   /* string payload at ptr+24 */
  char port[16]; snprintf(port, sizeof port, "%d", UNTAG(port_tagged));
  struct addrinfo hints = {0}, *res, *ai;
  hints.ai_family = AF_UNSPEC;        /* IPv4 or IPv6 */
  hints.ai_socktype = SOCK_STREAM;
  int gai = getaddrinfo(host, port, &hints, &res);
  if (gai != 0) return mdk_err(mdk_str_cstr(gai_strerror(gai)));
  int fd = -1, last = 0;
  for (ai = res; ai; ai = ai->ai_next) {
    fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
    if (fd < 0) { last = errno; continue; }
    if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
    last = errno; close(fd); fd = -1;
  }
  freeaddrinfo(res);
  if (fd < 0) return mdk_err(mdk_str_cstr(strerror(last)));
#ifdef SO_NOSIGPIPE                    /* macOS: suppress SIGPIPE on write-to-closed */
  int on = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
  return mdk_ok(TAG(fd));
}

/* netTcpListen : bindAddr -> port -> Result String Int  (listening fd).
 * SO_REUSEADDR set by default so a restarted server / repeated fixture rebinds. */
long long mdk_net_tcp_listen(long long addr_cell, long long port_tagged) {
  const char *addr = (const char *)addr_cell + 24;
  char port[16]; snprintf(port, sizeof port, "%d", UNTAG(port_tagged));
  struct addrinfo hints = {0}, *res;
  hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM; hints.ai_flags = AI_PASSIVE;
  int gai = getaddrinfo(addr[0] ? addr : NULL, port, &hints, &res);
  if (gai != 0) return mdk_err(mdk_str_cstr(gai_strerror(gai)));
  int fd = socket(res->ai_family, res->ai_socktype, res->ai_protocol);
  if (fd < 0) { int e = errno; freeaddrinfo(res); return mdk_err(mdk_str_cstr(strerror(e))); }
  int on = 1; setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
  if (bind(fd, res->ai_addr, res->ai_addrlen) != 0 || listen(fd, 128) != 0) {
    int e = errno; close(fd); freeaddrinfo(res); return mdk_err(mdk_str_cstr(strerror(e)));
  }
  freeaddrinfo(res);
  return mdk_ok(TAG(fd));
}

/* netListenPort : fd -> Result String Int  (actual bound port; for port-0 ephemeral) */
long long mdk_net_listen_port(long long fd_tagged) {
  struct sockaddr_storage ss; socklen_t len = sizeof ss;
  if (getsockname(UNTAG(fd_tagged), (struct sockaddr *)&ss, &len) != 0)
    return mdk_err(mdk_str_cstr(strerror(errno)));
  int port = (ss.ss_family == AF_INET6)
    ? ntohs(((struct sockaddr_in6 *)&ss)->sin6_port)
    : ntohs(((struct sockaddr_in  *)&ss)->sin_port);
  return mdk_ok(TAG(port));
}

long long mdk_net_tcp_accept(long long lis_tagged) {
  int c = accept(UNTAG(lis_tagged), NULL, NULL);   /* blocks */
  if (c < 0) return mdk_err(mdk_str_cstr(strerror(errno)));
#ifdef SO_NOSIGPIPE
  int on = 1; setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &on, sizeof on);
#endif
  return mdk_ok(TAG(c));
}

/* netSend : fd -> Array Int -> Result String Int  (count). Array cell = [len, tagged bytes...]. */
long long mdk_net_send(long long fd_tagged, long long arr) {
  long long *a = (long long *)arr; long long n = a[0];
  unsigned char *buf = (unsigned char *)mdk_alloc(n ? n : 1);
  for (long long i = 0; i < n; i++) buf[i] = (unsigned char)(a[i + 1] >> 1);
  int flags = 0;
#ifdef MSG_NOSIGNAL
  flags = MSG_NOSIGNAL;              /* Linux: suppress SIGPIPE on write-to-closed */
#endif
  ssize_t w = send(UNTAG(fd_tagged), buf, (size_t)n, flags);
  if (w < 0) return mdk_err(mdk_str_cstr(strerror(errno)));
  return mdk_ok(TAG((long long)w));
}

/* netRecv : fd -> maxBytes -> Result String (Array Int). Empty Array = EOF/peer-closed. */
long long mdk_net_recv(long long fd_tagged, long long max_tagged) {
  long long max = max_tagged >> 1;
  unsigned char *buf = (unsigned char *)mdk_alloc(max ? max : 1);
  ssize_t r = recv(UNTAG(fd_tagged), buf, (size_t)max, 0);
  if (r < 0) return mdk_err(mdk_str_cstr(strerror(errno)));
  long long *cell = (long long *)mdk_alloc((r + 1) * 8);   /* [len, tagged bytes...] */
  cell[0] = (long long)r;
  for (ssize_t i = 0; i < r; i++) cell[i + 1] = ((long long)buf[i] << 1) | 1;
  return mdk_ok((long long)cell);
}

long long mdk_net_close(long long fd_tagged) {
  int fd = UNTAG(fd_tagged);
  if (fd < 0) return mdk_ok(1);                  /* idempotent-safe */
  if (close(fd) != 0 && errno != EBADF) return mdk_err(mdk_str_cstr(strerror(errno)));
  return mdk_ok(1);                              /* Unit */
}

/* netShutdown, netSetTimeout (SO_RCVTIMEO/SO_SNDTIMEO via struct timeval): analogous. */
```

**Platform concerns (macOS + Linux, both POSIX):**

- **SIGPIPE on write-to-closed-peer** — the one real cross-platform trap. macOS has
  no `MSG_NOSIGNAL`; use per-socket `SO_NOSIGPIPE` at accept/connect. Linux has no
  `SO_NOSIGPIPE`; use `MSG_NOSIGNAL` per `send`. Both `#ifdef`-guarded above. (A
  belt-and-suspenders `signal(SIGPIPE, SIG_IGN)` at runtime init is also reasonable —
  fork sub-decision, low stakes.)
- **`getaddrinfo` with `AF_UNSPEC`** gives IPv4+IPv6 transparently; connect tries
  each address (the "happy path" loop). DNS is thus *inside* `netTcpConnect`, and
  also exposed standalone as `netResolve` (which returns the numeric IP strings via
  `inet_ntop`, built as a `mdk_cons` list like `mdk_list_dir`).
- **Blocking semantics:** `accept`/`recv`/`connect`/`send` block. `netSetTimeout`
  installs `SO_RCVTIMEO`/`SO_SNDTIMEO` so a hung peer surfaces as
  `Err "Operation timed out"` (`EAGAIN`/`EWOULDBLOCK` mapped) instead of hanging the
  process — essential for a blocking-only model.

**Wiring (mirror the file externs exactly):**
`llvm_preamble.mdk` gets `declare i64 @mdk_net_tcp_connect(i64)` … one per extern;
`llvm_emit.mdk` gets an **`isNetExtern` name-set + `emitNetExtern` arms** (a
*separate* family from `isFileExtern` — deliberately, so the wasm backend can reject
the whole set in one guard, §6). Each arm `emitArgs` then
`call i64 @mdk_net_<fn>(…)` returning `(reg, LTCon)`.

---

## 6. Interpreter + wasm posture (both explicit, not TODOs)

- **`medaka run` (tree-walking interpreter):** net externs are **unbound**, exactly
  like `readFile`/`runCommand`. They are **not** added to `eval.mdk`'s `primitives`
  list. A program that calls a net extern under `run` fails with `unbound
  identifier: netTcpConnect`. **This is the accepted, decided model** (fact 2): the
  interpreter is a pure deterministic oracle; **net programs use `medaka build`.**
  This is not a gap to close — it is the same contract as `fs`.
- **WasmGC backend:** net is **native-only**. `wasm_emit.mdk` does **not** implement
  the `isNetExtern` family; `medaka build --target wasm` on a program importing
  `net` **rejects** it (the capability-stratification gate `STDLIB.md` anticipates).
  Raw `socket(2)` has no WasmGC equivalent. A browser `fetch`-backed **`http`** client
  (different API surface) and WASI-sockets on non-browser runtimes are **future,
  separate designs** — explicitly out of scope here.
- **Fixpoint impact is low:** the compiler never imports `net`, so the only
  fixpoint-touching edits are the `isNetExtern`/`emitNetExtern` **registration
  lists** in `llvm_emit.mdk`. Batch the net externs into **one seed re-mint**
  checkpoint (per "defer seed re-mints").

---

## 7. `stdlib/net.mdk` API sketch

The ergonomic layer over the externs. Abstract handle types (unexported
constructors), `Result`-returning verbs, brackets, and byte/line helpers built on
`bytes`/`string`.

```medaka
module net

import bytes
import string

-- Opaque handles (constructors NOT exported: users cannot fabricate/confuse fds) --
data Socket     = Socket Int
data Listener   = Listener Int
type Connection = Socket          -- a connected socket; alias for readability

-- Client -------------------------------------------------------------------
connect : String -> Int -> <Net> Result String Connection
connect host port = mapResult Socket (netTcpConnect host port)

resolve : String -> <Net> Result String (List String)
resolve = netResolve

-- Server -------------------------------------------------------------------
listen : String -> Int -> <Net> Result String Listener
listen addr port = mapResult Listener (netTcpListen addr port)

listenPort : Listener -> <Net> Result String Int
listenPort (Listener fd) = netListenPort fd

accept : Listener -> <Net> Result String Connection
accept (Listener fd) = mapResult Socket (netTcpAccept fd)

-- Transfer -----------------------------------------------------------------
send : Connection -> Array Int -> <Net> Result String Int
send (Socket fd) bs = netSend fd bs

recv : Connection -> Int -> <Net> Result String (Array Int)
recv (Socket fd) n = netRecv fd n

close : Socket -> <Net> Result String Unit
close (Socket fd) = netClose fd

setTimeout : Socket -> Int -> <Net> Result String Unit
setTimeout (Socket fd) ms = netSetTimeout fd ms

-- Full-write / full-read loops (handle short send/recv — pure Medaka) -------
sendAll : Connection -> Array Int -> <Net> Result String Unit     -- loop until all bytes sent
recvAll : Connection -> <Net> Result String (Array Int)           -- loop recv until EOF (empty)

-- Text helpers over bytes/string ------------------------------------------
sendLine : Connection -> String -> <Net> Result String Unit       -- utf8 + "\n", via sendAll
recvLine : Connection -> <Net> Result String (Option String)      -- read to '\n' (None at EOF)

-- Brackets (the blessed leak-safe pattern, §4) -----------------------------
withConnection : String -> Int -> (Connection -> <Net> Result String a) -> <Net> Result String a
withListener   : String -> Int -> (Listener   -> <Net> Result String a) -> <Net> Result String a
serveLoop      : Listener -> (Connection -> <Net> Result String Unit) -> <Net> Result String Unit
```

**Doctest caveat (important):** because net externs are unbound under `medaka run`,
and **doctests execute via the interpreter**, `net.mdk` functions **cannot have
executable doctests**. Its verification comes from **compiled fixtures** (§8), not
`medaka test`. Doc-comments may show *non-executing* usage examples (type-level /
illustrative). This mirrors `fs`/`io` externs and must be called out so an
implementation agent does not waste a cycle writing doctests that the harness will
try (and fail) to run.

---

## 8. Staging plan + testability

### Testability (addressed honestly — the crux for an effectful, peer-requiring module)

Golden-diff harnesses run one program and diff stdout. Networking needs a **peer**.
Three testable configurations, in preference order:

1. **Single-process TCP loopback self-test (primary, hermetic).** One `medaka build`
   program: `listen "127.0.0.1" 0` → `listenPort` (read the OS-assigned ephemeral
   port) → `connect "127.0.0.1" thatPort` → `accept` → `send`/`recv` a small message
   → assert echo → `close`. **This works single-threaded** because the kernel
   completes the TCP handshake into the listen backlog: `connect` to a listening
   localhost socket returns as soon as the SYN is queued (*before* `accept` is
   called), and small payloads fit in socket buffers, so `send` before the peer
   `recv`s does not block. Deterministic, no external peer, **no hard-coded port**
   (port 0 + `listenPort` avoids CI collisions). This is *why* server externs and
   `netListenPort` are in v1. Gate: `test/diff_net.sh` diffs the program's stdout
   ("roundtrip ok").
2. **Two-process shell harness (for streaming / larger payloads).** `diff_net.sh`
   launches a compiled server program in the background (binds ephemeral, prints its
   port), then runs a compiled client against that port; diffs client stdout. Robust
   for cases where single-process buffering would deadlock (large streams). More
   moving parts (background process, port handshake via a temp file), so used only
   where config 1 can't reach.
3. **UDP loopback (if/when UDP lands, v1.5).** UDP `sendTo`/`recvFrom` to one's own
   bound port is connectionless → **no accept/connect blocking** → trivially
   single-process and hermetic. This is an argument for UDP being *easy* to test,
   noted for the v1.5 gate.

**DNS testing** uses `resolve "localhost"` (must yield `127.0.0.1`/`::1`) — hermetic,
no external network. Do **not** resolve public hostnames in the gate (non-hermetic,
flaky).

### Staging (ordered bites)

| # | Bite | Model | Agent | Gate |
|---|---|---|---|---|
| 1 | **Net externs + C batch** — 12 `mdk_net_*` in `medaka_rt.c`; `declare`s in `llvm_preamble.mdk`; `isNetExtern`+`emitNetExtern` in `llvm_emit.mdk`; extern sigs in `runtime.mdk`. **One seed re-mint.** | native | **Opus** (getaddrinfo/SIGPIPE platform care, emit-registration, owns the re-mint + `selfcompile_fixpoint`) | builds OCaml-free; fixpoint C3a/C3b green; a minimal build-and-run loopback probe compiles |
| 2 | **`stdlib/net.mdk`** — abstract handles, verbs, `sendAll`/`recvAll`/`sendLine`/`recvLine`, `withConnection`/`withListener`/`serveLoop`. Pure Medaka. | native | **Sonnet** (mechanical wrapping over the externs; no re-mint — `net` isn't compiler-imported) | typechecks; `medaka check stdlib/net.mdk` clean |
| 3 | **Gated fixtures + `test/diff_net.sh`** — the single-process loopback self-test (config 1) + a `resolve "localhost"` test; capture goldens. | native | **Opus** (harness design, hermeticity, ephemeral-port handshake) | `diff_net.sh` green; wasm-reject test (`build --target wasm` on a net-importing program errors) green |
| 4 | **(v1.5) UDP + socket options** — `netUdp*`, `netSetNoDelay`/`netSetReuse`; UDP loopback fixture. | native | Sonnet (externs, templated) + Opus (re-mint) | UDP loopback diff green |

**Re-mint discipline:** bites 1 and 4 each touch the `llvm_emit.mdk` registration
lists → each is **one** batched re-mint + fixpoint re-validation. Bites 2 and 3 do
not perturb the compiler build.

---

## 9. Design forks (need a human decision)

| # | Fork | Options | **Recommendation** |
|---|---|---|---|
| **F1** | **Blocking vs async v1** | (a) blocking; (b) integrate the `Async` monad now | **(a) blocking.** Every std baseline (Rust/Python/Zig) is blocking; async needs non-blocking + a `poll`/`select` extern feeding the cooperative scheduler — a whole follow-on. `setTimeout` makes blocking safe enough for v1. |
| **F2** | **TCP-only vs +UDP in v1** | (a) TCP only; (b) +UDP | **(a) TCP only in v1**, UDP in v1.5. UDP is small and additive; deferring keeps the v1 surface tight. (Counter-note: UDP is the *easiest* to test hermetically — if a UDP consumer appears, pull it forward cheaply.) |
| **F3** | **Client-only vs +server in v1** | (a) client only; (b) client + server | **(b) client + server.** Server externs are nearly free (same family) **and** the single-process loopback self-test *requires* a server to be hermetically testable. Client-only would force the fragile two-process harness as the *only* test path. |
| **F4** | **fd-as-Int vs abstract Socket type** | (a) raw `Int` everywhere; (b) abstract newtypes | **(b), split:** raw tagged `Int` at the **extern** boundary (simplest ABI, no new C cell), abstract `Socket`/`Listener`/`Connection` (unexported constructors) at the **stdlib** surface. Gets Int's ABI simplicity + Go-`Conn`-style type safety. |
| **F5** | **`<Net>` refinement granularity** | (a) host-only `PPrefix`; (b) Host×Port `Product`; (c) Host×Method `Product` (WS-4) | **(a) host-only `PPrefix`** for v1. Host is the security-relevant axis and `PPrefix`+α-recovery already deliver it with zero compiler work. Method is HTTP-level (belongs to a future `http` module on the WS-4 Product domain); Host×Port is a low-value future refinement. |
| **F6** | **How to test in the golden-diff harness** | (a) single-process loopback; (b) two-process shell harness; (c) mock/no real socket | **(a) single-process loopback** as primary (hermetic, deterministic, port-0 + `listenPort`), **(b) two-process** only where buffering would deadlock (large streams). Never (c) — a mock wouldn't exercise the C shims, which are the whole point. |
| **F7** | **SIGPIPE handling** | (a) per-socket `SO_NOSIGPIPE`/per-send `MSG_NOSIGNAL`; (b) global `signal(SIGPIPE, SIG_IGN)` at init; (c) both | **(c) both** (belt-and-suspenders) — cheap, and a stray SIGPIPE crashing the process is the nastiest cross-platform net bug. Low stakes. |
| **F8** | **Extern naming** | (a) `net*` prefix (`netTcpConnect`); (b) unprefixed (`tcpConnect`, P1's cut) | **(a) `net*` prefix** — clean `isNetExtern` name-set for the wasm-reject guard + extern-namespace hygiene. Cosmetic; flag only so the P1 §5 names aren't taken as final. |

---

## 10. Summary of recommendations

- **v1 scope:** blocking **TCP client + TCP server + DNS resolve**, with read/write
  **timeouts**, plaintext only. UDP/options → v1.5. TLS/HTTP/async/non-blocking →
  future.
- **12 externs**, `net*`-prefixed, `<Net "_">`-labelled, `Result String _` errors,
  raw tagged-`Int` fds at the boundary, wired exactly like the file externs
  (`runtime.mdk` + `medaka_rt.c` + `llvm_preamble.mdk` + a *separate* `isNetExtern`/
  `emitNetExtern` family for one-guard wasm rejection).
- **Effect:** host-only `PPrefix` refinement via existing α hole-fill; flows into
  `medaka manifest`/`check-policy` for free. Product/Host×Method is for a future
  `http` module, not v1 net.
- **Leak-safety:** `withConnection`/`withListener`/`serveLoop` brackets in
  `stdlib/net.mdk`; the panic-leak case is a non-problem (panic ends the process →
  OS reclaims fds), so the whole story reduces to "always close on the `Result`-error
  path," which the brackets guarantee.
- **Interpreter:** net unbound under `run` (accepted, like `fs`); **wasm:**
  native-only, `build --target wasm` rejects `net`.
- **Testability:** single-process **loopback self-test** (listen on
  `127.0.0.1:0` → `listenPort` → connect → accept → roundtrip), hermetic and
  deterministic; two-process shell harness only for streaming. This is the reason
  server + `netListenPort` are in v1.
- **Staging:** (1) externs+C [Opus, one re-mint] → (2) `stdlib/net.mdk` [Sonnet] →
  (3) fixtures + `diff_net.sh` + wasm-reject test [Opus] → (4) v1.5 UDP/options.
- **8 forks** enumerated with recommendations (§9).
