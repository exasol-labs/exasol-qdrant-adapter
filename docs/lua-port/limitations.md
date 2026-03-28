# Lua Adapter — Known Limitations

This document records the known downsides of replacing the Java adapter with a Lua adapter. These were accepted consciously as part of the lua-port decision.

---

## 1. No Custom TLS / Self-Signed Certificates

**What breaks:** Qdrant or Ollama endpoints secured with self-signed certificates or a private CA.

**Why:** Lua adapters run inside Exasol's UDF sandbox, which has no filesystem access. There is no way to load a custom CA bundle or a client certificate at runtime.

**Works fine:**
- Plain HTTP (the standard Docker Compose setup)
- Qdrant Cloud or any endpoint with a public CA–signed certificate

**Workaround for self-signed TLS:** Maintain a Java Virtual Schema adapter separately. The original Java source was removed from this repo but the architecture is documented in git history.

---

## 2. No Filesystem Access at Runtime

**What breaks:** Any operation that reads or writes files during adapter execution.

**Why:** Same UDF sandbox restriction as above.

**Impact for this adapter:** None in practice — all state comes from adapter properties and the CONNECTION object.

---

## 3. Stateless Execution Only

**What breaks:** Caching connections, pooling HTTP clients, or persisting state between calls.

**Why:** Each `adapter_call()` invocation is independent. No globals survive between calls.

**Impact for this adapter:** Each push-down makes fresh HTTP calls to Ollama and Qdrant. At low query volumes this is acceptable.

---

## 4. No Native Extensions

**What breaks:** C-based LuaRocks packages (e.g., native crypto, native HTTP with system TLS).

**Why:** The sandbox prevents loading shared objects.

**Impact for this adapter:** We use `socket.http` (bundled LuaSocket) for HTTP and `cjson` (bundled) for JSON — both pure-C but pre-loaded by Exasol, so this is not an issue in practice. Any *additional* dependencies must be pure Lua.
