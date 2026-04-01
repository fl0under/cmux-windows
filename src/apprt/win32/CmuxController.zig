const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const w32 = @import("win32.zig");
const Window = @import("Window.zig");
const Surface = @import("Surface.zig");
const Protocol = @import("../../cmux/ipc/Protocol.zig").Protocol;
const NotificationStore = @import("../../cmux/notifications/NotificationStore.zig").NotificationStore;
const CmuxServer = @import("../../cmux/ipc/Server.zig").Server;
const SplitTree = @import("../../datastruct/split_tree.zig").SplitTree;

pub const CmuxController = struct {
    allocator: Allocator,
    notifications: NotificationStore,
    server: CmuxServer,

    pub fn init(allocator: Allocator) CmuxController {
        return .{
            .allocator = allocator,
            .notifications = NotificationStore.init(allocator),
            .server = CmuxServer.init(allocator),
        };
    }

    pub fn deinit(self: *CmuxController) void {
        self.server.deinit();
        self.notifications.deinit();
    }

    pub fn start(self: *CmuxController, hwnd: w32.HWND) !void {
        try self.server.start(hwnd);
    }

    pub fn ipcMessage() u32 {
        return CmuxServer.WM_CMUX_IPC;
    }

    pub const PendingRequest = CmuxServer.PendingRequest;

    pub fn recordDesktopNotification(
        self: *CmuxController,
        target: apprt.Target,
        value: apprt.Action.Value(.desktop_notification),
    ) void {
        const workspace_id: u32 = switch (target) {
            .app => 0,
            .surface => |core_surface| blk: {
                const rt_surface = core_surface.rt_surface;
                const idx = rt_surface.parent_window.findTabIndex(rt_surface) orelse break :blk 0;
                break :blk @intCast(idx + 1);
            },
        };

        _ = self.notifications.add(workspace_id, value.title, value.body);
    }

    pub fn handlePendingRequest(
        self: *CmuxController,
        app: anytype,
        pending: *CmuxServer.PendingRequest,
    ) void {
        const response = self.processRequest(app, pending.allocator, pending.request) catch |err| blk: {
            break :blk self.makeErrorResponse(
                pending.allocator,
                null,
                -1,
                @errorName(err),
            ) catch pending.allocator.dupe(u8, "{\"error\":{\"code\":-1,\"message\":\"internal error\"}}\n") catch return;
        };

        pending.completeOwned(response);
    }

    fn processRequest(
        self: *CmuxController,
        app: anytype,
        allocator: Allocator,
        data: []const u8,
    ) ![]u8 {
        const line = if (std.mem.indexOfScalar(u8, data, '\n')) |idx|
            data[0..idx]
        else
            data;

        const method = try extractStringParamOwned(allocator, line, "method") orelse
            return self.makeErrorResponse(allocator, null, -32600, "invalid request");
        defer allocator.free(method);

        const id = extractIntParam(line, "id");

        var response = std.ArrayList(u8).init(allocator);
        errdefer response.deinit();
        const writer = response.writer();

        if (std.mem.eql(u8, method, "new-workspace")) {
            const name = try extractStringParamOwned(allocator, line, "name");
            defer if (name) |v| allocator.free(v);

            const window = try self.ensureWindow(app);
            _ = try window.addTab();
            const idx = window.activeTabIndex();
            if (name) |workspace_name| {
                const ztitle = try allocator.dupeZ(u8, workspace_name);
                defer allocator.free(ztitle);
                window.renameTabIndex(idx, ztitle);
            }

            var result = std.ArrayList(u8).init(allocator);
            defer result.deinit();
            try result.writer().print("{{\"workspace_id\":{d}}}", .{idx});
            try Protocol.writeSuccess(writer, id, result.items);
        } else if (std.mem.eql(u8, method, "close-workspace")) {
            const idx = extractIntParam(line, "index") orelse 0;
            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };
            if (idx < 0 or @as(usize, @intCast(idx)) >= window.tabCount()) {
                try Protocol.writeError(writer, id, -32602, "invalid workspace index");
                return try response.toOwnedSlice();
            }
            window.closeTabIndex(@intCast(idx));
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "switch-workspace")) {
            const idx = extractIntParam(line, "index") orelse {
                try Protocol.writeError(writer, id, -32602, "missing index param");
                return try response.toOwnedSlice();
            };
            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };
            if (idx < 0 or @as(usize, @intCast(idx)) >= window.tabCount()) {
                try Protocol.writeError(writer, id, -32602, "invalid workspace index");
                return try response.toOwnedSlice();
            }
            window.selectTabIndex(@intCast(idx));
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "rename-workspace")) {
            const name = try extractStringParamOwned(allocator, line, "name") orelse {
                try Protocol.writeError(writer, id, -32602, "missing name param");
                return try response.toOwnedSlice();
            };
            defer allocator.free(name);

            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };

            const idx = extractIntParam(line, "index") orelse @as(i64, @intCast(window.activeTabIndex()));
            if (idx < 0 or @as(usize, @intCast(idx)) >= window.tabCount()) {
                try Protocol.writeError(writer, id, -32602, "invalid workspace index");
                return try response.toOwnedSlice();
            }

            const ztitle = try allocator.dupeZ(u8, name);
            defer allocator.free(ztitle);
            window.renameTabIndex(@intCast(idx), ztitle);
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "split")) {
            const direction = try extractStringParamOwned(allocator, line, "direction") orelse
                try allocator.dupe(u8, "right");
            defer allocator.free(direction);

            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };

            const split_direction: SplitTree(Surface).Split.Direction = if (std.mem.eql(u8, direction, "left"))
                .left
            else if (std.mem.eql(u8, direction, "right"))
                .right
            else if (std.mem.eql(u8, direction, "up"))
                .up
            else if (std.mem.eql(u8, direction, "down"))
                .down
            else {
                try Protocol.writeError(writer, id, -32602, "invalid split direction");
                return try response.toOwnedSlice();
            };

            window.newSplit(split_direction) catch {
                try Protocol.writeError(writer, id, -1, "failed to create split");
                return try response.toOwnedSlice();
            };
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "close-pane")) {
            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };
            window.closeActivePane();
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "send-keys")) {
            const keys = try extractStringParamOwned(allocator, line, "keys") orelse {
                try Protocol.writeError(writer, id, -32602, "missing keys param");
                return try response.toOwnedSlice();
            };
            defer allocator.free(keys);

            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };

            const workspace_idx = extractIntParam(line, "workspace");
            const surface = if (workspace_idx) |idx|
                surfaceForWorkspace(window, idx)
            else
                window.getActiveSurface();

            if (surface == null) {
                try Protocol.writeError(writer, id, -32602, "invalid workspace index");
                return try response.toOwnedSlice();
            }

            surface.?.core_surface.textCallback(keys) catch {
                try Protocol.writeError(writer, id, -1, "failed to send keys");
                return try response.toOwnedSlice();
            };
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "notify")) {
            const title = try extractStringParamOwned(allocator, line, "title") orelse
                try allocator.dupe(u8, "Notification");
            defer allocator.free(title);

            const body = try extractStringParamOwned(allocator, line, "body") orelse
                try allocator.dupe(u8, "");
            defer allocator.free(body);

            const workspace_id: u32 = if (activeWindow(app)) |window|
                @intCast(window.activeTabIndex() + 1)
            else
                0;
            _ = self.notifications.add(workspace_id, title, body);

            const title_z = try allocator.dupeZ(u8, title);
            defer allocator.free(title_z);
            const body_z = try allocator.dupeZ(u8, body);
            defer allocator.free(body_z);
            _ = try app.performAction(.app, .desktop_notification, .{
                .title = title_z,
                .body = body_z,
            });

            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "open-url")) {
            const url = try extractStringParamOwned(allocator, line, "url") orelse {
                try Protocol.writeError(writer, id, -32602, "missing url param");
                return try response.toOwnedSlice();
            };
            defer allocator.free(url);

            _ = try app.performAction(.app, .open_url, .{
                .kind = .unknown,
                .url = url,
            });
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "list")) {
            try writer.writeAll("{");
            if (id) |req_id| {
                try writer.print("\"id\":{d},", .{req_id});
            }
            try writer.writeAll("\"result\":");
            const window = activeWindow(app);
            try writer.writeByte('[');
            if (window) |win| {
                var name_buf: [512]u8 = undefined;
                for (0..win.tabCount()) |i| {
                    if (i > 0) try writer.writeByte(',');
                    try writer.writeAll("{\"id\":");
                    try writer.print("{d}", .{i});
                    try writer.writeAll(",\"name\":");
                    try writeJsonString(writer, win.getTabTitleUtf8(i, &name_buf));
                    try writer.writeAll(",\"active\":");
                    try writer.writeAll(if (i == win.activeTabIndex()) "true" else "false");
                    try writer.writeByte('}');
                }
            }
            try writer.writeAll("]}\n");
        } else if (std.mem.eql(u8, method, "focus")) {
            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };
            if (extractIntParam(line, "workspace")) |idx| {
                if (idx < 0 or @as(usize, @intCast(idx)) >= window.tabCount()) {
                    try Protocol.writeError(writer, id, -32602, "invalid workspace index");
                    return try response.toOwnedSlice();
                }
                window.selectTabIndex(@intCast(idx));
            }
            window.focusWindow();
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "move-focus")) {
            const direction = try extractStringParamOwned(allocator, line, "direction") orelse {
                try Protocol.writeError(writer, id, -32602, "missing direction param");
                return try response.toOwnedSlice();
            };
            defer allocator.free(direction);

            const window = activeWindow(app) orelse {
                try Protocol.writeError(writer, id, -1, "no active window");
                return try response.toOwnedSlice();
            };

            const goto_target: apprt.action.GotoSplit = if (std.mem.eql(u8, direction, "left"))
                .left
            else if (std.mem.eql(u8, direction, "right"))
                .right
            else if (std.mem.eql(u8, direction, "up"))
                .up
            else if (std.mem.eql(u8, direction, "down"))
                .down
            else if (std.mem.eql(u8, direction, "next"))
                .next
            else if (std.mem.eql(u8, direction, "previous"))
                .previous
            else {
                try Protocol.writeError(writer, id, -32602, "invalid focus direction");
                return try response.toOwnedSlice();
            };

            window.gotoSplit(goto_target);
            try Protocol.writeSuccess(writer, id, null);
        } else if (std.mem.eql(u8, method, "status")) {
            try writer.writeAll("{");
            if (id) |req_id| {
                try writer.print("\"id\":{d},", .{req_id});
            }
            try writer.writeAll("\"result\":{");
            try writer.print("\"windows\":{d},", .{app.windows.items.len});
            try writer.print("\"unread\":{d},", .{self.notifications.total_unread});
            if (activeWindow(app)) |win| {
                try writer.print("\"workspaces\":{d},\"active\":{d}", .{
                    win.tabCount(),
                    win.activeTabIndex(),
                });
            } else {
                try writer.writeAll("\"workspaces\":0,\"active\":-1");
            }
            try writer.writeAll("}}\n");
        } else {
            try Protocol.writeError(writer, id, -32601, "method not found");
        }

        return try response.toOwnedSlice();
    }

    fn ensureWindow(self: *CmuxController, app: anytype) !*Window {
        _ = self;
        if (activeWindow(app)) |window| return window;
        _ = try app.performAction(.app, .new_window, {});
        return activeWindow(app) orelse error.NoActiveWindow;
    }

    fn activeWindow(app: anytype) ?*Window {
        if (app.core_app.focusedSurface()) |focused| {
            return focused.rt_surface.parent_window;
        }
        if (app.windows.items.len == 0) return null;
        return app.windows.items[app.windows.items.len - 1];
    }

    fn surfaceForWorkspace(window: *Window, idx: i64) ?*Surface {
        if (idx < 0) return null;
        const workspace_idx: usize = @intCast(idx);
        if (workspace_idx >= window.tabCount()) return null;
        return window.getTabActiveSurface(workspace_idx);
    }

    fn makeErrorResponse(
        self: *CmuxController,
        allocator: Allocator,
        id: ?i64,
        code: i32,
        message: []const u8,
    ) ![]u8 {
        _ = self;
        var buf = std.ArrayList(u8).init(allocator);
        errdefer buf.deinit();
        try Protocol.writeError(buf.writer(), id, code, message);
        return try buf.toOwnedSlice();
    }

    fn extractStringParamOwned(
        allocator: Allocator,
        data: []const u8,
        key: []const u8,
    ) !?[]u8 {
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
        const start_pos = std.mem.indexOf(u8, data, search) orelse return null;
        var i = start_pos + search.len;
        var out = std.ArrayList(u8).init(allocator);
        errdefer out.deinit();

        var escaped = false;
        while (i < data.len) : (i += 1) {
            const ch = data[i];
            if (escaped) {
                try out.append(switch (ch) {
                    '"' => '"',
                    '\\' => '\\',
                    '/' => '/',
                    'b' => 0x08,
                    'f' => 0x0C,
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => ch,
                });
                escaped = false;
                continue;
            }

            switch (ch) {
                '\\' => escaped = true,
                '"' => return try out.toOwnedSlice(),
                else => try out.append(ch),
            }
        }

        return null;
    }

    fn extractIntParam(data: []const u8, key: []const u8) ?i64 {
        var search_buf: [64]u8 = undefined;
        const search = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;

        const start_pos = std.mem.indexOf(u8, data, search) orelse return null;
        var i = start_pos + search.len;
        while (i < data.len and (data[i] == ' ' or data[i] == '\t')) : (i += 1) {}

        var negative = false;
        if (i < data.len and data[i] == '-') {
            negative = true;
            i += 1;
        }

        var result: i64 = 0;
        var found = false;
        while (i < data.len and data[i] >= '0' and data[i] <= '9') : (i += 1) {
            result = result * 10 + (data[i] - '0');
            found = true;
        }

        if (!found) return null;
        return if (negative) -result else result;
    }

    fn writeJsonString(writer: anytype, value: []const u8) !void {
        try writer.writeByte('"');
        for (value) |ch| {
            switch (ch) {
                '"' => try writer.writeAll("\\\""),
                '\\' => try writer.writeAll("\\\\"),
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.writeByte(ch),
            }
        }
        try writer.writeByte('"');
    }
};
