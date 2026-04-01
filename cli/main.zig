const std = @import("std");

/// cmux CLI — command-line interface for controlling cmux-windows.
///
/// Connects to the running cmux-windows process via Named Pipes
/// and sends JSON-RPC commands.
///
/// Usage:
///   cmux new [name] [--shell "wsl.exe -d Ubuntu"]
///   cmux close [index]
///   cmux switch <index>
///   cmux rename <name>
///   cmux split [right|down]
///   cmux send-keys <workspace> <keys>
///   cmux notify <title> [body]
///   cmux open <url> [--split]
///   cmux list
///   cmux status
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 2) {
        printUsage();
        return;
    }

    const command = args[1];
    const pipe_name = "\\\\.\\pipe\\cmux";

    // Build JSON-RPC request
    var request_buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&request_buf);
    const writer = fbs.writer();

    if (std.mem.eql(u8, command, "new")) {
        try writer.writeAll("{\"method\":\"new-workspace\",\"params\":{");
        if (args.len > 2) {
            try writer.print("\"name\":\"{s}\"", .{args[2]});
        }
        // Check for --shell flag
        var i: usize = 3;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--shell") and i + 1 < args.len) {
                if (args.len > 3 or i > 3) try writer.writeAll(",");
                try writer.print("\"shell\":\"{s}\"", .{args[i + 1]});
                i += 1;
            }
        }
        try writer.writeAll("},\"id\":1}\n");
    } else if (std.mem.eql(u8, command, "close")) {
        const index = if (args.len > 2)
            std.fmt.parseInt(i64, args[2], 10) catch 0
        else
            0;
        try writer.print("{{\"method\":\"close-workspace\",\"params\":{{\"index\":{d}}},\"id\":1}}\n", .{index});
    } else if (std.mem.eql(u8, command, "switch")) {
        if (args.len < 3) {
            std.debug.print("Usage: cmux switch <index>\n", .{});
            return;
        }
        const index = std.fmt.parseInt(i64, args[2], 10) catch {
            std.debug.print("Error: invalid index\n", .{});
            return;
        };
        try writer.print("{{\"method\":\"switch-workspace\",\"params\":{{\"index\":{d}}},\"id\":1}}\n", .{index});
    } else if (std.mem.eql(u8, command, "rename")) {
        if (args.len < 3) {
            std.debug.print("Usage: cmux rename <name>\n", .{});
            return;
        }
        try writer.print("{{\"method\":\"rename-workspace\",\"params\":{{\"name\":\"{s}\"}},\"id\":1}}\n", .{args[2]});
    } else if (std.mem.eql(u8, command, "split")) {
        const direction = if (args.len > 2) args[2] else "right";
        try writer.print("{{\"method\":\"split\",\"params\":{{\"direction\":\"{s}\"}},\"id\":1}}\n", .{direction});
    } else if (std.mem.eql(u8, command, "send-keys")) {
        if (args.len < 4) {
            std.debug.print("Usage: cmux send-keys <workspace> <keys>\n", .{});
            return;
        }
        try writer.print("{{\"method\":\"send-keys\",\"params\":{{\"workspace\":{s},\"keys\":\"{s}\"}},\"id\":1}}\n", .{ args[2], args[3] });
    } else if (std.mem.eql(u8, command, "notify")) {
        if (args.len < 3) {
            std.debug.print("Usage: cmux notify <title> [body]\n", .{});
            return;
        }
        const body = if (args.len > 3) args[3] else "";
        try writer.print("{{\"method\":\"notify\",\"params\":{{\"title\":\"{s}\",\"body\":\"{s}\"}},\"id\":1}}\n", .{ args[2], body });
    } else if (std.mem.eql(u8, command, "open")) {
        if (args.len < 3) {
            std.debug.print("Usage: cmux open <url> [--split]\n", .{});
            return;
        }
        const do_split = args.len > 3 and std.mem.eql(u8, args[3], "--split");
        try writer.print("{{\"method\":\"open-url\",\"params\":{{\"url\":\"{s}\",\"split\":{s}}},\"id\":1}}\n", .{
            args[2],
            if (do_split) "true" else "false",
        });
    } else if (std.mem.eql(u8, command, "list")) {
        try writer.writeAll("{\"method\":\"list\",\"id\":1}\n");
    } else if (std.mem.eql(u8, command, "status")) {
        try writer.writeAll("{\"method\":\"status\",\"id\":1}\n");
    } else if (std.mem.eql(u8, command, "help") or std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        printUsage();
        return;
    } else {
        std.debug.print("Unknown command: {s}\n", .{command});
        printUsage();
        return;
    }

    const request = fbs.getWritten();

    // Send to named pipe
    const response = sendToPipe(allocator, pipe_name, request) catch |err| {
        switch (err) {
            error.ConnectFailed => {
                std.debug.print("Error: Could not connect to cmux. Is cmux-windows running?\n", .{});
                std.process.exit(1);
            },
            else => {
                std.debug.print("Error: {}\n", .{err});
                std.process.exit(1);
            },
        }
    };
    defer allocator.free(response);

    // Print response
    const stdout = std.io.getStdOut().writer();
    try stdout.writeAll(response);
    if (response.len > 0 and response[response.len - 1] != '\n') {
        try stdout.writeAll("\n");
    }
}

fn sendToPipe(allocator: Allocator, pipe_name: [*:0]const u8, request: []const u8) ![]u8 {
    // Win32 Named Pipe client
    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const OPEN_EXISTING: u32 = 3;

    const CreateFileA = @extern(*const fn ([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.C) HANDLE, .{
        .library_name = "kernel32",
        .name = "CreateFileA",
    });
    const CloseHandle = @extern(*const fn (HANDLE) callconv(.C) i32, .{
        .library_name = "kernel32",
        .name = "CloseHandle",
    });
    const ReadFile = @extern(*const fn (HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.C) i32, .{
        .library_name = "kernel32",
        .name = "ReadFile",
    });
    const WriteFile = @extern(*const fn (HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.C) i32, .{
        .library_name = "kernel32",
        .name = "WriteFile",
    });

    const pipe = CreateFileA(pipe_name, GENERIC_READ | GENERIC_WRITE, 0, null, OPEN_EXISTING, 0, null);
    if (pipe == INVALID_HANDLE_VALUE) return error.ConnectFailed;
    defer _ = CloseHandle(pipe);

    var bytes_written: u32 = 0;
    if (WriteFile(pipe, request.ptr, @intCast(request.len), &bytes_written, null) == 0) {
        return error.WriteFailed;
    }

    var response_buf: [4096]u8 = undefined;
    var bytes_read: u32 = 0;
    if (ReadFile(pipe, &response_buf, 4096, &bytes_read, null) == 0 or bytes_read == 0) {
        return error.ReadFailed;
    }

    return try allocator.dupe(u8, response_buf[0..bytes_read]);
}

fn printUsage() void {
    const usage =
        \\cmux - Command-line interface for cmux-windows
        \\
        \\Usage:
        \\  cmux <command> [options]
        \\
        \\Commands:
        \\  new [name] [--shell <cmd>]   Create a new workspace
        \\  close [index]                Close a workspace
        \\  switch <index>               Switch to a workspace by index
        \\  rename <name>                Rename the active workspace
        \\  split [right|down]           Split the active pane
        \\  send-keys <ws> <keys>        Send keystrokes to a workspace
        \\  notify <title> [body]        Send a notification
        \\  open <url> [--split]         Open URL in embedded browser
        \\  list                         List all workspaces
        \\  status                       Show cmux status
        \\  help                         Show this help
        \\
        \\Examples:
        \\  cmux new my-feature --shell "wsl.exe -d Ubuntu"
        \\  cmux split right
        \\  cmux notify "Build complete"
        \\  cmux send-keys 0 "npm test\n"
        \\  cmux open http://localhost:3000 --split
        \\
    ;
    std.debug.print("{s}", .{usage});
}

const Allocator = std.mem.Allocator;
