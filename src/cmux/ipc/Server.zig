const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");
const Protocol = @import("Protocol.zig").Protocol;

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

    pub const PendingRequest = struct {
        allocator: Allocator,
        request: []u8,
        response: ?[]u8 = null,
        completed: bool = false,
        mutex: std.Thread.Mutex = .{},
        cond: std.Thread.Condition = .{},

        pub fn init(allocator: Allocator, request: []const u8) !*PendingRequest {
            const pending = try allocator.create(PendingRequest);
            errdefer allocator.destroy(pending);

            pending.* = .{
                .allocator = allocator,
                .request = try allocator.dupe(u8, request),
            };
            return pending;
        }

        pub fn deinit(self: *PendingRequest) void {
            self.allocator.free(self.request);
            if (self.response) |response| self.allocator.free(response);
            self.allocator.destroy(self);
        }

        pub fn completeOwned(self: *PendingRequest, response: []u8) void {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.response = response;
            self.completed = true;
            self.cond.signal();
        }

        pub fn wait(self: *PendingRequest) ?[]u8 {
            self.mutex.lock();
            defer self.mutex.unlock();

            while (!self.completed) {
                self.cond.wait(&self.mutex);
            }

            const response = self.response;
            self.response = null;
            return response;
        }
    };

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

        const pending = try PendingRequest.init(self.allocator, buf[0..bytes_read]);
        defer pending.deinit();

        const hwnd = self.app_hwnd orelse return error.NoAppWindow;
        if (w32.PostMessageW(
            hwnd,
            WM_CMUX_IPC,
            0,
            @as(isize, @bitCast(@intFromPtr(pending))),
        ) == 0) {
            return error.DispatchFailed;
        }

        const response = pending.wait() orelse blk: {
            var response_buf: [128]u8 = undefined;
            var fbs = std.io.fixedBufferStream(&response_buf);
            Protocol.writeError(fbs.writer(), null, -1, "no response") catch {};
            break :blk try self.allocator.dupe(u8, fbs.getWritten());
        };
        defer self.allocator.free(response);

        // Write response
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
