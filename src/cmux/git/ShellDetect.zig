const std = @import("std");
const Allocator = std.mem.Allocator;

/// Detects available shells and routes commands through the correct
/// executable. Handles WSL detection and distro enumeration.
pub const ShellDetect = struct {
    allocator: Allocator,

    pub const ShellInfo = struct {
        name: [64]u8 = [_]u8{0} ** 64,
        name_len: u8 = 0,
        command: [256]u8 = [_]u8{0} ** 256,
        command_len: u16 = 0,
        shell_type: ShellType,
        available: bool = false,

        pub fn getName(self: *const ShellInfo) []const u8 {
            return self.name[0..self.name_len];
        }

        pub fn getCommand(self: *const ShellInfo) []const u8 {
            return self.command[0..self.command_len];
        }
    };

    pub const ShellType = enum {
        powershell,
        cmd,
        wsl,
        git_bash,
    };

    pub fn init(allocator: Allocator) ShellDetect {
        return .{ .allocator = allocator };
    }

    /// Detect all available shells on the system.
    pub fn detectShells(self: *ShellDetect) ![8]ShellInfo {
        var shells: [8]ShellInfo = [_]ShellInfo{.{ .shell_type = .cmd }} ** 8;
        var count: usize = 0;

        // PowerShell 7+ (pwsh.exe)
        shells[count] = .{
            .shell_type = .powershell,
            .available = self.commandExists("pwsh.exe"),
        };
        setStr(&shells[count].name, &shells[count].name_len, "PowerShell 7");
        setStr(&shells[count].command, &shells[count].command_len, "pwsh.exe");
        count += 1;

        // PowerShell 5.1 (always available on Windows 10+)
        shells[count] = .{
            .shell_type = .powershell,
            .available = true,
        };
        setStr(&shells[count].name, &shells[count].name_len, "PowerShell 5.1");
        setStr(&shells[count].command, &shells[count].command_len, "powershell.exe");
        count += 1;

        // CMD (always available)
        shells[count] = .{
            .shell_type = .cmd,
            .available = true,
        };
        setStr(&shells[count].name, &shells[count].name_len, "Command Prompt");
        setStr(&shells[count].command, &shells[count].command_len, "cmd.exe");
        count += 1;

        // WSL (default distro)
        shells[count] = .{
            .shell_type = .wsl,
            .available = self.commandExists("wsl.exe"),
        };
        setStr(&shells[count].name, &shells[count].name_len, "WSL");
        setStr(&shells[count].command, &shells[count].command_len, "wsl.exe");
        count += 1;

        // Git Bash
        shells[count] = .{
            .shell_type = .git_bash,
            .available = self.gitBashExists(),
        };
        setStr(&shells[count].name, &shells[count].name_len, "Git Bash");
        setStr(&shells[count].command, &shells[count].command_len, "C:\\Program Files\\Git\\bin\\bash.exe");
        count += 1;

        return shells;
    }

    /// List installed WSL distributions.
    /// Returns a list of distro names (e.g., "Ubuntu", "Debian").
    pub fn listWslDistros(self: *ShellDetect) ![][]u8 {
        var distros = std.ArrayList([]u8).init(self.allocator);
        errdefer {
            for (distros.items) |d| self.allocator.free(d);
            distros.deinit();
        }

        // Run: wsl.exe -l -q
        const result = self.runCommand(&.{ "wsl.exe", "-l", "-q" }) catch return try distros.toOwnedSlice();

        defer self.allocator.free(result);

        // Parse output — one distro name per line (UTF-16 output from wsl.exe, but
        // when captured via ConPTY it may come as UTF-8)
        var iter = std.mem.splitAny(u8, result, "\r\n");
        while (iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
            if (trimmed.len == 0) continue;
            // Skip null bytes (from UTF-16 leftovers)
            var clean = std.ArrayList(u8).init(self.allocator);
            for (trimmed) |c| {
                if (c != 0) try clean.append(c);
            }
            if (clean.items.len > 0) {
                try distros.append(try clean.toOwnedSlice());
            } else {
                clean.deinit();
            }
        }

        return try distros.toOwnedSlice();
    }

    /// Check whether WSL2 is being used (vs WSL1).
    pub fn isWsl2(self: *ShellDetect, distro: ?[]const u8) bool {
        // Run: wsl.exe --status or check via wsl.exe -l -v
        _ = self;
        _ = distro;
        // TODO: Parse `wsl.exe -l -v` output for WSL version column
        return true; // Assume WSL2 by default
    }

    fn commandExists(self: *ShellDetect, cmd: []const u8) bool {
        const result = self.runCommand(&.{ "where.exe", cmd }) catch return false;
        self.allocator.free(result);
        return true;
    }

    fn gitBashExists(self: *ShellDetect) bool {
        _ = self;
        // Check common installation path
        const path = "C:\\Program Files\\Git\\bin\\bash.exe";
        return std.fs.cwd().access(path, .{}) != error.FileNotFound;
    }

    fn runCommand(self: *ShellDetect, argv: []const []const u8) ![]u8 {
        var child = std.process.Child.init(argv, self.allocator);
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 8192);
        const term = try child.wait();

        if (term.Exited != 0) {
            self.allocator.free(stdout);
            return error.CommandFailed;
        }

        return stdout;
    }

    fn setStr(buf: anytype, len: anytype, value: []const u8) void {
        const l = @min(value.len, buf.len);
        @memcpy(buf[0..l], value[0..l]);
        len.* = @intCast(l);
    }
};
