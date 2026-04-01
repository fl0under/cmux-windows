const std = @import("std");
const Allocator = std.mem.Allocator;

/// Scans for listening TCP ports on the local machine using the Win32
/// GetTcpTable2 API. WSL2 ports are forwarded to the host, so this
/// single API covers both native and WSL workspaces.
pub const PortScanner = struct {
    allocator: Allocator,

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
        // On Windows, we'd call GetTcpTable2() from iphlpapi.dll.
        // For now, provide a stub that will be filled in when building on Windows.
        var ports = std.ArrayList(u16).init(self.allocator);
        errdefer ports.deinit();

        // TODO: Actual Win32 implementation:
        // 1. Call GetTcpTable2(null, &size, 0) to get required buffer size
        // 2. Allocate buffer
        // 3. Call GetTcpTable2(buf, &size, 1) to get sorted table
        // 4. Filter for MIB_TCP_STATE_LISTEN (2)
        // 5. Extract local port (ntohs)

        return try ports.toOwnedSlice();
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
};
