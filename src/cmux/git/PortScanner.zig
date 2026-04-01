const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const windows = @import("../../os/windows.zig");

/// Scans for listening TCP ports on the local machine using the Win32
/// GetTcpTable2 API. WSL2 ports are forwarded to the host, so this
/// single API covers both native and WSL workspaces.
pub const PortScanner = struct {
    allocator: Allocator,

    const AF_INET: u32 = 2;
    const ERROR_INSUFFICIENT_BUFFER: u32 = 122;
    const MIB_TCP_STATE_LISTEN: u32 = 2;
    const TCP_TABLE_OWNER_PID_LISTENER: u32 = 3;

    const MIB_TCPROW_OWNER_PID = extern struct {
        dwState: u32,
        dwLocalAddr: u32,
        dwLocalPort: u32,
        dwRemoteAddr: u32,
        dwRemotePort: u32,
        dwOwningPid: u32,
    };

    const MIB_TCPTABLE_OWNER_PID = extern struct {
        dwNumEntries: u32,
        table: [1]MIB_TCPROW_OWNER_PID,
    };

    /// Common development server ports to watch for.
    pub const INTERESTING_PORTS = [_]u16{
        3000, 3001, 3030, 3333, // Node.js, React, etc.
        4000, 4200, 4321, // Phoenix, Angular, Astro
        5000, 5173, 5174, // Flask, Vite
        8000, 8080, 8081, 8443, // Django, Tomcat, etc.
        9000, 9090, // Various
    };

    pub const PortInfo = struct {
        port: u16,
        pid: u32,
        state: State,

        pub const State = enum {
            listening,
            established,
            other,
        };
    };

    pub fn init(allocator: Allocator) PortScanner {
        return .{ .allocator = allocator };
    }

    /// Scan for listening ports. Returns a list of ports that are in
    /// the LISTEN state. Caller owns the returned slice.
    pub fn scanListeningPorts(self: *PortScanner) ![]u16 {
        var ports = std.ArrayList(u16).init(self.allocator);
        errdefer ports.deinit();

        if (builtin.os.tag != .windows) {
            return try ports.toOwnedSlice();
        }

        var size: windows.DWORD = 0;
        const first = GetExtendedTcpTable(
            null,
            &size,
            windows.FALSE,
            AF_INET,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        );
        if (first != ERROR_INSUFFICIENT_BUFFER or size == 0) {
            return try ports.toOwnedSlice();
        }

        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);

        const result = GetExtendedTcpTable(
            @ptrCast(buffer.ptr),
            &size,
            windows.FALSE,
            AF_INET,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        );
        if (result != 0) {
            return try ports.toOwnedSlice();
        }

        const table: *const MIB_TCPTABLE_OWNER_PID = @ptrCast(@alignCast(buffer.ptr));
        const rows: [*]const MIB_TCPROW_OWNER_PID = @ptrCast(&table.table[0]);
        for (rows[0..table.dwNumEntries]) |row| {
            if (row.dwState != MIB_TCP_STATE_LISTEN) continue;
            try appendUniquePort(&ports, ntohsFromDw(row.dwLocalPort));
        }

        return try ports.toOwnedSlice();
    }

    /// Scan for interesting listening ports owned by a specific process ID.
    /// If pid is null, falls back to global interesting port scanning.
    pub fn scanInterestingPortsForPid(self: *PortScanner, pid: ?u32) ![]u16 {
        if (pid == null) return self.scanInterestingPorts();

        var interesting = std.ArrayList(u16).init(self.allocator);
        errdefer interesting.deinit();

        if (builtin.os.tag != .windows) {
            return try interesting.toOwnedSlice();
        }

        var size: windows.DWORD = 0;
        const first = GetExtendedTcpTable(
            null,
            &size,
            windows.FALSE,
            AF_INET,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        );
        if (first != ERROR_INSUFFICIENT_BUFFER or size == 0) {
            return try interesting.toOwnedSlice();
        }

        const buffer = try self.allocator.alloc(u8, size);
        defer self.allocator.free(buffer);

        const result = GetExtendedTcpTable(
            @ptrCast(buffer.ptr),
            &size,
            windows.FALSE,
            AF_INET,
            TCP_TABLE_OWNER_PID_LISTENER,
            0,
        );
        if (result != 0) {
            return try interesting.toOwnedSlice();
        }

        const table: *const MIB_TCPTABLE_OWNER_PID = @ptrCast(@alignCast(buffer.ptr));
        const rows: [*]const MIB_TCPROW_OWNER_PID = @ptrCast(&table.table[0]);
        for (rows[0..table.dwNumEntries]) |row| {
            if (row.dwState != MIB_TCP_STATE_LISTEN) continue;
            if (row.dwOwningPid != pid.?) continue;
            const port = ntohsFromDw(row.dwLocalPort);
            if (!isInterestingPort(port)) continue;
            try appendUniquePort(&interesting, port);
        }

        return try interesting.toOwnedSlice();
    }

    /// Scan for listening ports that match common dev server ports.
    pub fn scanInterestingPorts(self: *PortScanner) ![]u16 {
        const all = try self.scanListeningPorts();
        defer self.allocator.free(all);

        var interesting = std.ArrayList(u16).init(self.allocator);
        errdefer interesting.deinit();

        for (all) |port| {
            for (INTERESTING_PORTS) |p| {
                if (port == p) {
                    try interesting.append(port);
                    break;
                }
            }
        }

        return try interesting.toOwnedSlice();
    }

    /// Check if a specific port is listening.
    pub fn isPortListening(self: *PortScanner, port: u16) !bool {
        const all = try self.scanListeningPorts();
        defer self.allocator.free(all);

        for (all) |p| {
            if (p == port) return true;
        }
        return false;
    }

    fn isInterestingPort(port: u16) bool {
        for (INTERESTING_PORTS) |p| {
            if (p == port) return true;
        }
        return false;
    }

    fn appendUniquePort(list: *std.ArrayList(u16), port: u16) !void {
        for (list.items) |existing| {
            if (existing == port) return;
        }
        try list.append(port);
    }

    fn ntohsFromDw(value: u32) u16 {
        return @as(u16, @truncate(((value & 0xFF) << 8) | ((value >> 8) & 0xFF)));
    }
};

extern "iphlpapi" fn GetExtendedTcpTable(
    pTcpTable: ?*anyopaque,
    pdwSize: *windows.DWORD,
    bOrder: windows.BOOL,
    ulAf: windows.ULONG,
    table_class: windows.ULONG,
    reserved: windows.ULONG,
) callconv(.winapi) windows.DWORD;
