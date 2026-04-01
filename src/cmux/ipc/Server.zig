const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");
const Protocol = @import("Protocol.zig").Protocol;
const Commands = @import("Commands.zig");

/// Named pipe server running in the main cmux-windows process.
/// Listens on \\.\pipe\cmux for incoming JSON-RPC requests from the CLI.
///
/// The server runs on a dedicated thread and dispatches commands to the
/// main thread via PostMessage.
pub const Server = struct {
    allocator: Allocator,
    pipe_handle: ?HANDLE = null,
    running: bool = false,
    thread: ?std.Thread = null,
    app_hwnd: ?w32.HWND = null,
    command_handler: ?*Commands = null,

    pub const PIPE_NAME = "\\\\.\\pipe\\cmux";
    pub const BUFFER_SIZE: u32 = 4096;

    /// Custom message to post to app HWND when an IPC command arrives.
    pub const WM_CMUX_IPC = w32.WM_USER + 300;

    pub fn init(allocator: Allocator) Server {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Server) void {
        self.stop();
    }

    /// Start the named pipe server on a background thread.
    pub fn start(self: *Server, app_hwnd: w32.HWND) !void {
        self.app_hwnd = app_hwnd;
        self.running = true;
        self.thread = try std.Thread.spawn(.{}, serverThread, .{self});
    }

    /// Stop the server and wait for the thread to finish.
    pub fn stop(self: *Server) void {
        self.running = false;
        // Close the pipe to unblock any waiting ConnectNamedPipe
        if (self.pipe_handle) |handle| {
            _ = CloseHandle(handle);
            self.pipe_handle = null;
        }
        if (self.thread) |t| {
            t.join();
            self.thread = null;
        }
    }

    fn serverThread(self: *Server) void {
        while (self.running) {
            self.acceptAndHandle() catch |err| {
                std.log.err("IPC server error: {}", .{err});
                // Brief pause before retrying
                std.time.sleep(100 * std.time.ns_per_ms);
            };
        }
    }

    fn acceptAndHandle(self: *Server) !void {
        // Create named pipe instance
        const pipe = CreateNamedPipeA(
            PIPE_NAME,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES,
            BUFFER_SIZE,
            BUFFER_SIZE,
            0,
            null,
        );

        if (pipe == INVALID_HANDLE_VALUE) {
            return error.CreatePipeFailed;
        }
        self.pipe_handle = pipe;

        // Wait for a client to connect
        const connected = ConnectNamedPipe(pipe, null);
        if (connected == 0 and GetLastError() != ERROR_PIPE_CONNECTED) {
            _ = CloseHandle(pipe);
            self.pipe_handle = null;
            return error.ConnectFailed;
        }

        defer {
            _ = DisconnectNamedPipe(pipe);
            _ = CloseHandle(pipe);
            self.pipe_handle = null;
        }

        // Read request
        var buf: [BUFFER_SIZE]u8 = undefined;
        var bytes_read: u32 = 0;
        const read_ok = ReadFile(pipe, &buf, BUFFER_SIZE, &bytes_read, null);
        if (read_ok == 0 or bytes_read == 0) return;

        const data = buf[0..bytes_read];

        // Process request
        var response_buf: [BUFFER_SIZE]u8 = undefined;
        var fbs = std.io.fixedBufferStream(&response_buf);

        if (self.command_handler) |handler| {
            handler.handleRequest(data, fbs.writer()) catch {
                Protocol.writeError(fbs.writer(), null, -1, "internal error") catch {};
            };
        } else {
            Protocol.writeError(fbs.writer(), null, -1, "no command handler") catch {};
        }

        // Write response
        const response = fbs.getWritten();
        if (response.len > 0) {
            var bytes_written: u32 = 0;
            _ = WriteFile(pipe, response.ptr, @intCast(response.len), &bytes_written, null);
            _ = FlushFileBuffers(pipe);
        }
    }

    // --- Win32 Named Pipe API ---

    const HANDLE = *anyopaque;
    const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
    const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
    const PIPE_TYPE_BYTE: u32 = 0x00000000;
    const PIPE_READMODE_BYTE: u32 = 0x00000000;
    const PIPE_WAIT: u32 = 0x00000000;
    const PIPE_UNLIMITED_INSTANCES: u32 = 255;
    const ERROR_PIPE_CONNECTED: u32 = 535;

    extern "kernel32" fn CreateNamedPipeA(
        lpName: [*:0]const u8,
        dwOpenMode: u32,
        dwPipeMode: u32,
        nMaxInstances: u32,
        nOutBufferSize: u32,
        nInBufferSize: u32,
        nDefaultTimeOut: u32,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.C) HANDLE;

    extern "kernel32" fn ConnectNamedPipe(hNamedPipe: HANDLE, lpOverlapped: ?*anyopaque) callconv(.C) i32;
    extern "kernel32" fn DisconnectNamedPipe(hNamedPipe: HANDLE) callconv(.C) i32;
    extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.C) i32;
    extern "kernel32" fn ReadFile(hFile: HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.C) i32;
    extern "kernel32" fn WriteFile(hFile: HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.C) i32;
    extern "kernel32" fn FlushFileBuffers(hFile: HANDLE) callconv(.C) i32;
    extern "kernel32" fn GetLastError() callconv(.C) u32;
};
