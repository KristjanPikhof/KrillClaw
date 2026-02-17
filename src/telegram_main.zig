const std = @import("std");
const config_mod = @import("config.zig");
const telegram = @import("telegram.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    const stdout = std.fs.File.stdout().deprecatedWriter();

    const config = try config_mod.load(allocator);

    if (config.api_key.len == 0 and config.provider != .ollama) {
        try stdout.print("Error: API key not set for provider.\n", .{});
        std.process.exit(1);
    }

    telegram.run(allocator, config) catch |err| {
        switch (err) {
            error.MissingBotToken => try stdout.print("Error: TELEGRAM_BOT_TOKEN is required.\n", .{}),
            error.MissingAllowedChatIds => try stdout.print("Error: TELEGRAM_ALLOWED_CHAT_IDS is required and must be non-empty.\n", .{}),
            error.InvalidAllowedChatId => try stdout.print("Error: TELEGRAM_ALLOWED_CHAT_IDS contains invalid id value.\n", .{}),
            else => try stdout.print("Error: telegram bot failed to start ({})\n", .{err}),
        }
        std.process.exit(1);
    };
}
