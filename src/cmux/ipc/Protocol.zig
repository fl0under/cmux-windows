const std = @import("std");
const Allocator = std.mem.Allocator;

/// JSON-RPC style protocol for CLI ↔ app communication over Named Pipes.
/// Wire format: newline-delimited JSON.
///
/// Request:  {"method": "new-workspace", "params": {"name": "feature-auth"}, "id": 1}
/// Response: {"result": {"workspace_id": 3}, "id": 1}
/// Error:    {"error": {"code": -1, "message": "unknown method"}, "id": 1}
pub const Protocol = struct {
    pub const Request = struct {
        method: []const u8,
        params: ?std.json.Value = null,
        id: ?i64 = null,
    };

    pub const Response = struct {
        id: ?i64 = null,
        result: ?std.json.Value = null,
        @"error": ?ErrorObj = null,
    };

    pub const ErrorObj = struct {
        code: i32,
        message: []const u8,
    };

    /// Known RPC methods.
    pub const Method = enum {
        @"new-workspace",
        @"close-workspace",
        @"switch-workspace",
        @"rename-workspace",
        split,
        @"close-pane",
        @"send-keys",
        notify,
        @"open-url",
        list,
        focus,
        @"move-focus",
        status,

        pub fn fromString(s: []const u8) ?Method {
            inline for (std.meta.fields(Method)) |field| {
                if (std.mem.eql(u8, s, field.name)) {
                    return @enumFromInt(field.value);
                }
            }
            return null;
        }
    };

    /// Parse a JSON request from a byte buffer.
    pub fn parseRequest(allocator: Allocator, data: []const u8) !Request {
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, data, .{});
        defer parsed.deinit();

        const obj = parsed.value.object;

        const method = obj.get("method") orelse return error.MissingMethod;
        if (method != .string) return error.InvalidMethod;

        return .{
            .method = try allocator.dupe(u8, method.string),
            .params = if (obj.get("params")) |p| p else null,
            .id = if (obj.get("id")) |id_val| switch (id_val) {
                .integer => |i| i,
                else => null,
            } else null,
        };
    }

    /// Serialize a success response.
    pub fn writeSuccess(writer: anytype, id: ?i64, result_value: ?[]const u8) !void {
        try writer.writeAll("{");
        if (id) |i| {
            try writer.print("\"id\":{d},", .{i});
        }
        if (result_value) |val| {
            try writer.print("\"result\":{s}", .{val});
        } else {
            try writer.writeAll("\"result\":null");
        }
        try writer.writeAll("}\n");
    }

    /// Serialize an error response.
    pub fn writeError(writer: anytype, id: ?i64, code: i32, message: []const u8) !void {
        try writer.writeAll("{");
        if (id) |i| {
            try writer.print("\"id\":{d},", .{i});
        }
        try writer.print("\"error\":{{\"code\":{d},\"message\":\"{s}\"}}", .{ code, message });
        try writer.writeAll("}\n");
    }
};
