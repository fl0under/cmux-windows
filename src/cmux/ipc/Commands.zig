const std = @import("std");
const Allocator = std.mem.Allocator;
const Protocol = @import("Protocol.zig").Protocol;
const WorkspaceManager = @import("../workspace/WorkspaceManager.zig").WorkspaceManager;
const NotificationStore = @import("../notifications/NotificationStore.zig").NotificationStore;

/// Command handlers for IPC requests. Bridges JSON-RPC methods to
/// workspace manager, notification system, and other cmux subsystems.
pub const Commands = @This();

allocator: Allocator,
workspace_manager: ?*WorkspaceManager = null,
notification_store: ?*NotificationStore = null,

pub fn init(allocator: Allocator) Commands {
    return .{ .allocator = allocator };
}

/// Handle a raw JSON-RPC request and write the response.
pub fn handleRequest(self: *Commands, data: []const u8, writer: anytype) !void {
    // Find the newline-terminated JSON
    const line = if (std.mem.indexOf(u8, data, "\n")) |nl|
        data[0..nl]
    else
        data;

    // Parse method name quickly
    const method_name = extractMethod(line) orelse {
        try Protocol.writeError(writer, null, -32600, "invalid request");
        return;
    };

    const id = extractId(line);

    const method = Protocol.Method.fromString(method_name) orelse {
        try Protocol.writeError(writer, id, -32601, "method not found");
        return;
    };

    switch (method) {
        .@"new-workspace" => try self.handleNewWorkspace(line, id, writer),
        .@"close-workspace" => try self.handleCloseWorkspace(line, id, writer),
        .@"switch-workspace" => try self.handleSwitchWorkspace(line, id, writer),
        .@"rename-workspace" => try self.handleRenameWorkspace(line, id, writer),
        .split => try self.handleSplit(line, id, writer),
        .@"close-pane" => try self.handleClosePane(id, writer),
        .@"send-keys" => try self.handleSendKeys(line, id, writer),
        .notify => try self.handleNotify(line, id, writer),
        .@"open-url" => try self.handleOpenUrl(line, id, writer),
        .list => try self.handleList(id, writer),
        .focus => try self.handleFocus(line, id, writer),
        .@"move-focus" => try self.handleMoveFocus(line, id, writer),
        .status => try self.handleStatus(id, writer),
    }
}

fn handleNewWorkspace(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    const mgr = self.workspace_manager orelse {
        try Protocol.writeError(writer, id, -1, "no workspace manager");
        return;
    };

    const name = extractStringParam(data, "name");
    const shell = extractStringParam(data, "shell");

    const ws = mgr.createWorkspace(name, shell) catch {
        try Protocol.writeError(writer, id, -1, "failed to create workspace");
        return;
    };

    var buf: [128]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{{\"workspace_id\":{d}}}", .{ws.id}) catch "{}";
    try Protocol.writeSuccess(writer, id, result);
}

fn handleCloseWorkspace(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    const mgr = self.workspace_manager orelse {
        try Protocol.writeError(writer, id, -1, "no workspace manager");
        return;
    };

    const index = extractIntParam(data, "index") orelse {
        try Protocol.writeError(writer, id, -32602, "missing index param");
        return;
    };

    mgr.closeWorkspace(@intCast(index));
    try Protocol.writeSuccess(writer, id, null);
}

fn handleSwitchWorkspace(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    const mgr = self.workspace_manager orelse {
        try Protocol.writeError(writer, id, -1, "no workspace manager");
        return;
    };

    const index = extractIntParam(data, "index") orelse {
        try Protocol.writeError(writer, id, -32602, "missing index param");
        return;
    };

    mgr.switchTo(@intCast(index));
    try Protocol.writeSuccess(writer, id, null);
}

fn handleRenameWorkspace(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    const mgr = self.workspace_manager orelse {
        try Protocol.writeError(writer, id, -1, "no workspace manager");
        return;
    };

    const name = extractStringParam(data, "name") orelse {
        try Protocol.writeError(writer, id, -32602, "missing name param");
        return;
    };

    const index = extractIntParam(data, "index") orelse @as(i64, @intCast(mgr.active_index));
    mgr.rename(@intCast(index), name);
    try Protocol.writeSuccess(writer, id, null);
}

fn handleSplit(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    _ = self;
    _ = data;
    // TODO: Implement split via workspace's SplitContainer
    try Protocol.writeSuccess(writer, id, null);
}

fn handleClosePane(self: *Commands, id: ?i64, writer: anytype) !void {
    _ = self;
    // TODO: Implement close pane
    try Protocol.writeSuccess(writer, id, null);
}

fn handleSendKeys(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    _ = self;
    _ = data;
    // TODO: Inject keystrokes into the active terminal surface
    try Protocol.writeSuccess(writer, id, null);
}

fn handleNotify(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    const store = self.notification_store orelse {
        try Protocol.writeError(writer, id, -1, "no notification store");
        return;
    };

    const title = extractStringParam(data, "title") orelse "Notification";
    const body = extractStringParam(data, "body") orelse "";

    // Add to store (workspace 0 = global)
    _ = store.add(0, title, body);

    try Protocol.writeSuccess(writer, id, null);
}

fn handleOpenUrl(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    _ = self;
    _ = data;
    // TODO: Open URL in embedded browser or split
    try Protocol.writeSuccess(writer, id, null);
}

fn handleList(self: *Commands, id: ?i64, writer: anytype) !void {
    const mgr = self.workspace_manager orelse {
        try Protocol.writeError(writer, id, -1, "no workspace manager");
        return;
    };

    var buf: [2048]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();

    try w.writeAll("[");
    for (mgr.workspaces.items, 0..) |ws, i| {
        if (i > 0) try w.writeAll(",");
        try w.print("{{\"id\":{d},\"name\":\"{s}\",\"active\":{s}}}", .{
            ws.id,
            ws.getName(),
            if (ws.is_active) "true" else "false",
        });
    }
    try w.writeAll("]");

    try Protocol.writeSuccess(writer, id, fbs.getWritten());
}

fn handleFocus(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    _ = self;
    _ = data;
    // TODO: Focus a specific workspace/pane
    try Protocol.writeSuccess(writer, id, null);
}

fn handleMoveFocus(self: *Commands, data: []const u8, id: ?i64, writer: anytype) !void {
    _ = self;
    _ = data;
    // TODO: Move focus directionally
    try Protocol.writeSuccess(writer, id, null);
}

fn handleStatus(self: *Commands, id: ?i64, writer: anytype) !void {
    const mgr = self.workspace_manager orelse {
        try Protocol.writeError(writer, id, -1, "no workspace manager");
        return;
    };

    var buf: [512]u8 = undefined;
    const result = std.fmt.bufPrint(&buf, "{{\"workspaces\":{d},\"active\":{d}}}", .{
        mgr.count(),
        mgr.active_index,
    }) catch "{}";

    try Protocol.writeSuccess(writer, id, result);
}

// --- Simple JSON string extraction helpers ---
// These avoid full JSON parsing for performance on the hot path.

fn extractMethod(data: []const u8) ?[]const u8 {
    return extractStringParam(data, "method");
}

fn extractStringParam(data: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value"
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, data, search) orelse return null;
    const value_start = start_pos + search.len;
    const value_end = std.mem.indexOfPos(u8, data, value_start, "\"") orelse return null;

    return data[value_start..value_end];
}

fn extractId(data: []const u8) ?i64 {
    return extractIntParam(data, "id");
}

fn extractIntParam(data: []const u8, key: []const u8) ?i64 {
    var search_buf: [64]u8 = undefined;
    const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

    const start_pos = std.mem.indexOf(u8, data, search) orelse return null;
    const value_start = start_pos + search.len;

    // Skip whitespace
    var i = value_start;
    while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}

    // Parse integer
    var negative = false;
    if (i < data.len and data[i] == '-') {
        negative = true;
        i += 1;
    }

    var result: i64 = 0;
    var found = false;
    while (i < data.len and data[i] >= '0' and data[i] <= '9') {
        result = result * 10 + (data[i] - '0');
        found = true;
        i += 1;
    }

    if (!found) return null;
    return if (negative) -result else result;
}
