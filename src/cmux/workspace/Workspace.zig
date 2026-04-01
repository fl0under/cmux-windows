const std = @import("std");
const Allocator = std.mem.Allocator;
const SplitContainer = @import("../ui/SplitContainer.zig").SplitContainer;
const SidebarTab = @import("../ui/SidebarTab.zig");

/// A workspace represents a named terminal session with optional split panes,
/// shell configuration, and associated metadata (git, ports, notifications).
pub const Workspace = struct {
    allocator: Allocator,

    /// Unique workspace ID (monotonically increasing).
    id: u32,

    /// Display name (user-editable).
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,

    /// Shell configuration for this workspace.
    shell_command: [256]u8 = [_]u8{0} ** 256,
    shell_command_len: u16 = 0,
    shell_type: ShellType = .powershell,

    /// Working directory. For WSL shells, this is a Linux path.
    /// For native shells, this is a Win32 path.
    cwd: [512]u8 = [_]u8{0} ** 512,
    cwd_len: u16 = 0,

    /// Split pane tree for this workspace.
    splits: SplitContainer,

    /// Sidebar tab metadata (updated periodically).
    tab_meta: SidebarTab,

    /// Whether this workspace is currently active/visible.
    is_active: bool = false,

    /// Creation timestamp.
    created_at: i64 = 0,

    pub const ShellType = enum {
        powershell,
        cmd,
        wsl,
        git_bash,
        custom,

        /// Detect shell type from a command string.
        pub fn fromCommand(cmd: []const u8) ShellType {
            if (std.mem.indexOf(u8, cmd, "wsl") != null) return .wsl;
            if (std.mem.indexOf(u8, cmd, "pwsh") != null) return .powershell;
            if (std.mem.indexOf(u8, cmd, "powershell") != null) return .powershell;
            if (std.mem.indexOf(u8, cmd, "cmd") != null) return .cmd;
            if (std.mem.indexOf(u8, cmd, "bash") != null) return .git_bash;
            return .custom;
        }

        /// Convert to sidebar tab shell type.
        pub fn toTabShellType(self: ShellType) SidebarTab.ShellType {
            return switch (self) {
                .powershell => .powershell,
                .cmd => .cmd,
                .wsl => .wsl,
                .git_bash => .git_bash,
                .custom => .custom,
            };
        }
    };

    pub fn init(allocator: Allocator, id: u32, name: []const u8) Workspace {
        var ws = Workspace{
            .allocator = allocator,
            .id = id,
            .splits = SplitContainer.init(allocator),
            .tab_meta = SidebarTab.init(name),
        };
        ws.setName(name);
        return ws;
    }

    pub fn deinit(self: *Workspace) void {
        self.splits.deinit();
    }

    pub fn setName(self: *Workspace, name: []const u8) void {
        const len = @min(name.len, self.name.len);
        @memcpy(self.name[0..len], name[0..len]);
        self.name_len = @intCast(len);
        self.tab_meta.setName(name);
    }

    pub fn getName(self: *const Workspace) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn setShellCommand(self: *Workspace, cmd: []const u8) void {
        const len = @min(cmd.len, self.shell_command.len);
        @memcpy(self.shell_command[0..len], cmd[0..len]);
        self.shell_command_len = @intCast(len);
        self.shell_type = ShellType.fromCommand(cmd);
        self.tab_meta.shell_type = self.shell_type.toTabShellType();
    }

    pub fn getShellCommand(self: *const Workspace) []const u8 {
        return self.shell_command[0..self.shell_command_len];
    }

    pub fn setCwd(self: *Workspace, cwd: []const u8) void {
        const len = @min(cwd.len, self.cwd.len);
        @memcpy(self.cwd[0..len], cwd[0..len]);
        self.cwd_len = @intCast(len);
        self.tab_meta.setCwd(cwd);
    }

    pub fn getCwd(self: *const Workspace) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    /// Check if this workspace uses a WSL shell.
    pub fn isWsl(self: *const Workspace) bool {
        return self.shell_type == .wsl;
    }

    /// Serialize workspace state to JSON for session restore.
    pub fn toJson(self: *const Workspace, writer: anytype) !void {
        try writer.beginObject();

        try writer.objectField("id");
        try writer.write(self.id);

        try writer.objectField("name");
        try writer.write(self.getName());

        try writer.objectField("shell_command");
        try writer.write(self.getShellCommand());

        try writer.objectField("shell_type");
        try writer.write(@tagName(self.shell_type));

        try writer.objectField("cwd");
        try writer.write(self.getCwd());

        try writer.endObject();
    }
};
