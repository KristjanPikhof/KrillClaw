const std = @import("std");
const Agent = @import("agent.zig").Agent;
const types = @import("types.zig");
const json = @import("json.zig");

const TELEGRAM_BASE = "https://api.telegram.org";

pub const BotError = error{
    MissingBotToken,
    MissingAllowedChatIds,
    InvalidAllowedChatId,
};

const BotConfig = struct {
    token: []const u8,
    allowed_chat_ids: []i64,
    poll_timeout_secs: u32,
    max_reply_chars: usize,
};

pub fn run(allocator: std.mem.Allocator, base_config: types.Config) !void {
    const stdout = std.fs.File.stdout().deprecatedWriter();
    const cfg = try loadConfig(allocator);

    try stdout.print("telegram bot: starting long-poll loop\n", .{});

    var http_client = std.http.Client{ .allocator = allocator };
    defer http_client.deinit();

    var offset: i64 = 0;
    while (true) {
        var updates = fetchUpdates(allocator, &http_client, cfg, offset) catch |err| {
            try stdout.print("telegram: getUpdates failed: {}\n", .{err});
            std.Thread.sleep(1 * std.time.ns_per_s);
            continue;
        };
        defer freeUpdates(allocator, &updates);

        for (updates.items) |upd| {
            if (upd.update_id >= offset) offset = upd.update_id + 1;

            if (upd.chat_id == null or upd.text == null) continue;
            const chat_id = upd.chat_id.?;
            const text = upd.text.?;

            if (!isAllowedChat(cfg.allowed_chat_ids, chat_id)) continue;

            if (std.mem.eql(u8, text, "/start") or std.mem.eql(u8, text, "/help")) {
                sendChunks(allocator, &http_client, cfg, chat_id,
                    "YoctoClaw Telegram bot. Send a message and I'll run it through the in-process agent.") catch |err| {
                    try stdout.print("telegram: help reply failed: {}\n", .{err});
                };
                continue;
            }

            var run_cfg = base_config;
            run_cfg.streaming = false;
            var arena = std.heap.ArenaAllocator.init(allocator);
            defer arena.deinit();
            const msg_allocator = arena.allocator();

            var agent = Agent.init(msg_allocator, run_cfg);
            defer agent.deinit();

            const reply_local = agent.runForResponse(text) catch |err| {
                try stdout.print("telegram: agent run failed: {}\n", .{err});
                sendChunks(allocator, &http_client, cfg, chat_id,
                    "Sorry, I hit an internal error while processing that.") catch {};
                continue;
            };
            const reply = allocator.dupe(u8, reply_local) catch {
                sendChunks(allocator, &http_client, cfg, chat_id,
                    "Sorry, I ran out of memory while preparing the reply.") catch {};
                continue;
            };
            defer allocator.free(reply);

            sendChunks(allocator, &http_client, cfg, chat_id, reply) catch |err| {
                try stdout.print("telegram: sendMessage failed: {}\n", .{err});
            };
        }
    }
}

const Update = struct {
    update_id: i64,
    chat_id: ?i64,
    text: ?[]const u8,
};

fn fetchUpdates(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    cfg: BotConfig,
    offset: i64,
) !std.ArrayList(Update) {
    const url = try std.fmt.allocPrint(allocator, "{s}/bot{s}/getUpdates?timeout={d}&offset={d}", .{
        TELEGRAM_BASE,
        cfg.token,
        cfg.poll_timeout_secs,
        offset,
    });
    defer allocator.free(url);

    const body = try requestJson(allocator, http_client, .GET, url, null);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidResponse;
    const ok_v = root.object.get("ok") orelse return error.InvalidResponse;
    if (ok_v != .bool or !ok_v.bool) return error.InvalidResponse;

    const result_v = root.object.get("result") orelse return error.InvalidResponse;
    if (result_v != .array) return error.InvalidResponse;

    var updates: std.ArrayList(Update) = .{};
    for (result_v.array.items) |item| {
        if (item != .object) continue;
        const update_id_v = item.object.get("update_id") orelse continue;
        if (update_id_v != .integer) continue;

        var chat_id: ?i64 = null;
        var text: ?[]const u8 = null;

        if (item.object.get("message")) |msg_v| {
            if (msg_v == .object) {
                if (msg_v.object.get("chat")) |chat_v| {
                    if (chat_v == .object) {
                        if (chat_v.object.get("id")) |id_v| {
                            if (id_v == .integer) chat_id = @intCast(id_v.integer);
                        }
                    }
                }
                if (msg_v.object.get("text")) |text_v| {
                    if (text_v == .string) text = try allocator.dupe(u8, text_v.string);
                }
            }
        }

        try updates.append(allocator, .{
            .update_id = @intCast(update_id_v.integer),
            .chat_id = chat_id,
            .text = text,
        });
    }

    return updates;
}

fn sendChunks(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    cfg: BotConfig,
    chat_id: i64,
    message: []const u8,
) !void {
    if (message.len == 0) {
        try sendMessage(allocator, http_client, cfg, chat_id, "(no output)");
        return;
    }

    var start: usize = 0;
    while (start < message.len) {
        const hard_end = @min(start + cfg.max_reply_chars, message.len);
        const end = utf8SafeEnd(message, start, hard_end);
        const chunk = message[start..end];
        try sendMessage(allocator, http_client, cfg, chat_id, chunk);
        start = end;
    }
}

fn utf8SafeEnd(s: []const u8, start: usize, hard_end: usize) usize {
    if (hard_end >= s.len or hard_end <= start) return hard_end;

    var end = hard_end;
    while (end > start and (s[end] & 0b1100_0000) == 0b1000_0000) : (end -= 1) {}

    if (end == start) return hard_end;
    return end;
}

fn sendMessage(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    cfg: BotConfig,
    chat_id: i64,
    text: []const u8,
) !void {
    const url = try std.fmt.allocPrint(allocator, "{s}/bot{s}/sendMessage", .{ TELEGRAM_BASE, cfg.token });
    defer allocator.free(url);

    var body_list: std.ArrayList(u8) = .{};
    defer body_list.deinit(allocator);
    const w = body_list.writer(allocator);
    try w.print("{{\"chat_id\":{d},\"text\":\"", .{chat_id});
    try json.writeEscaped(w, text);
    try w.writeAll("\"}");

    const resp = try requestJson(allocator, http_client, .POST, url, body_list.items);
    defer allocator.free(resp);
}

fn requestJson(
    allocator: std.mem.Allocator,
    http_client: *std.http.Client,
    method: std.http.Method,
    url: []const u8,
    body: ?[]const u8,
) ![]u8 {
    const uri = try std.Uri.parse(url);
    const headers: []const std.http.Header = if (body != null)
        &.{.{ .name = "content-type", .value = "application/json" }}
    else
        &.{};

    var req = try http_client.request(method, uri, .{ .extra_headers = headers });
    defer req.deinit();

    if (body) |b| {
        req.transfer_encoding = .{ .content_length = b.len };
        var send_body = try req.sendBodyUnflushed(&.{});
        try send_body.writer.writeAll(b);
        try send_body.end();
    } else {
        try req.sendBodiless();
    }

    req.connection.?.flush() catch {};

    var head_buf: [16384]u8 = undefined;
    var response = try req.receiveHead(&head_buf);

    var transfer_buf: [8192]u8 = undefined;
    const reader = response.reader(&transfer_buf);
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var read_buf: [4096]u8 = undefined;
    while (true) {
        const n = try reader.readSliceShort(&read_buf);
        if (n == 0) break;
        try out.appendSlice(allocator, read_buf[0..n]);
    }

    if (response.head.status != .ok) return error.HttpError;
    return out.toOwnedSlice(allocator);
}

fn loadConfig(allocator: std.mem.Allocator) !BotConfig {
    const token = std.process.getEnvVarOwned(allocator, "TELEGRAM_BOT_TOKEN") catch return BotError.MissingBotToken;
    const allowed_raw = std.process.getEnvVarOwned(allocator, "TELEGRAM_ALLOWED_CHAT_IDS") catch return BotError.MissingAllowedChatIds;
    defer allocator.free(allowed_raw);
    if (std.mem.trim(u8, allowed_raw, &std.ascii.whitespace).len == 0) return BotError.MissingAllowedChatIds;

    var allowed: std.ArrayList(i64) = .{};
    var it = std.mem.splitScalar(u8, allowed_raw, ',');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, &std.ascii.whitespace);
        if (part.len == 0) continue;
        const id = std.fmt.parseInt(i64, part, 10) catch return BotError.InvalidAllowedChatId;
        try allowed.append(allocator, id);
    }
    if (allowed.items.len == 0) return BotError.MissingAllowedChatIds;

    const poll_timeout = parseEnvInt(allocator, u32, "TELEGRAM_POLL_TIMEOUT", 30);
    const max_reply_chars = parseEnvInt(allocator, usize, "TELEGRAM_MAX_REPLY_CHARS", 4000);
    const reply_cap = if (max_reply_chars == 0) 4000 else @min(max_reply_chars, 4000);

    return .{
        .token = token,
        .allowed_chat_ids = try allowed.toOwnedSlice(allocator),
        .poll_timeout_secs = poll_timeout,
        .max_reply_chars = reply_cap,
    };
}

fn parseEnvInt(allocator: std.mem.Allocator, comptime T: type, name: []const u8, default_value: T) T {
    const raw = std.process.getEnvVarOwned(allocator, name) catch return default_value;
    defer allocator.free(raw);
    return std.fmt.parseInt(T, raw, 10) catch default_value;
}

fn isAllowedChat(allowed: []const i64, chat_id: i64) bool {
    for (allowed) |id| {
        if (id == chat_id) return true;
    }
    return false;
}

fn freeUpdates(allocator: std.mem.Allocator, updates: *std.ArrayList(Update)) void {
    for (updates.items) |u| {
        if (u.text) |t| allocator.free(t);
    }
    updates.deinit(allocator);
}
