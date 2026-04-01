const std = @import("std");
const Allocator = std.mem.Allocator;
const Protocol = @import("Protocol.zig").Protocol;
const Server = @import("Server.zig").Server;

/// Named pipe client for the cmux CLI tool.
/// Connects to the running cmux-windows process and sends JSON-RPC commands.
pub const Client = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) Client {
        return .{ .allocator = allocator };
    }

    /// Send a JSON-RPC request and return the response.
    pub fn send(self: *Client, method: []const u8, params_json: ?[]const u8) ![]u8 {
        // Build JSON request
        var request_buf: [Server.BUFFER_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&request_buf);
        const writer = fbs.writer();

        try writer.writeAll("{\"method\":\"");
        try writer.writeAll(method);
        try writer.writeAll("\"");

        if (params_json) |params| {
            try writer.writeAll(",\"params\":");
            try writer.writeAll(params);
        }

        try writer.writeAll(",\"id\":1}\n");

        const request = fbs.getWritten();

        // Connect to named pipe
        const pipe = CreateFileA(
            Server.PIPE_NAME,
            GENERIC_READ | GENERIC_WRITE,
            0,
            null,
            OPEN_EXISTING,
            0,
            null,
        );

        if (pipe == INVALID_HANDLE_VALUE) {
            return error.ConnectFailed;
        }
        defer _ = CloseHandle(pipe);

        // Write request
        var bytes_written: u32 = 0;
        const write_ok = WriteFile(
            pipe,
            request.ptr,
            @intCast(request.len),
            &bytes_written,
            null,
        );
        if (write_ok == 0) return error.WriteFailed;

        // Read response
        var response_buf: [Server.BUFFER_SIZE]u8 = undefined;
        var bytes_read: u32 = 0;
        const read_ok = ReadFile(
            pipe,
            &response_buf,
            Server.BUFFER_SIZE,
            &bytes_read,
            null,
        );
        if (read_ok == 0 or bytes_read == 0) return error.ReadFailed;

        return try self.allocator.dupe(u8, response_buf[0..bytes_read]);
    }

    // --- Win32 File API for pipe client ---

    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const GENERIC_READ: u32 = 0x80000000;
    const GENERIC_WRITE: u32 = 0x40000000;
    const OPEN_EXISTING: u32 = 3;

    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) callconv(.C) HANDLE;

    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.C) i32;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.C) i32;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.C) i32;
};
