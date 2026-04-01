const std = @import("std");
const Allocator = std.mem.Allocator;

/// Represents metadata displayed for a single tab in the sidebar.
/// Each tab corresponds to one workspace.
pub const SidebarTab = @This();

/// Display name for the workspace.
name: [128]u8 = [_]u8{0} ** 128,
name_len: u8 = 0,

/// Shell type indicator.
shell_type: ShellType = .powershell,

/// Current working directory (as displayed — Linux path for WSL, Win32 path for native).
cwd: [256]u8 = [_]u8{0} ** 256,
cwd_len: u16 = 0,

/// Git branch name (empty if not in a git repo).
git_branch: [64]u8 = [_]u8{0} ** 64,
git_branch_len: u8 = 0,

/// PR number (0 = no PR).
pr_number: u32 = 0,

/// Listening ports detected for this workspace.
ports: [8]u16 = [_]u16{0} ** 8,
port_count: u8 = 0,

/// Latest notification text snippet.
last_notification: [128]u8 = [_]u8{0} ** 128,
last_notification_len: u8 = 0,

/// Number of unread notifications.
unread_count: u16 = 0,

/// Whether this tab is the active/focused workspace.
is_active: bool = false,

/// Shell type for display and command routing.
pub const ShellType = enum {
    powershell,
    cmd,
    wsl,
    git_bash,
    custom,

    pub fn icon(self: ShellType) []const u8 {
        return switch (self) {
            .powershell => "PS",
            .cmd => ">_",
            .wsl => "🐧",
            .git_bash => "GB",
            .custom => "??",
        };
    }

    pub fn displayName(self: ShellType) []const u8 {
        return switch (self) {
            .powershell => "PowerShell",
            .cmd => "CMD",
            .wsl => "WSL",
            .git_bash => "Git Bash",
            .custom => "Custom",
        };
    }
};

/// Create a new tab with a given name.
pub fn init(name: []const u8) SidebarTab {
    var tab = SidebarTab{};
    tab.setName(name);
    return tab;
}

/// Set the display name.
pub fn setName(self: *SidebarTab, name: []const u8) void {
    const len = @min(name.len, self.name.len);
    @memcpy(self.name[0..len], name[0..len]);
    self.name_len = @intCast(len);
}

/// Get the display name as a slice.
pub fn getName(self: *const SidebarTab) []const u8 {
    return self.name[0..self.name_len];
}

/// Set the CWD string.
pub fn setCwd(self: *SidebarTab, cwd: []const u8) void {
    const len = @min(cwd.len, self.cwd.len);
    @memcpy(self.cwd[0..len], cwd[0..len]);
    self.cwd_len = @intCast(len);
}

/// Get the CWD as a slice.
pub fn getCwd(self: *const SidebarTab) []const u8 {
    return self.cwd[0..self.cwd_len];
}

/// Set the git branch.
pub fn setGitBranch(self: *SidebarTab, branch: []const u8) void {
    const len = @min(branch.len, self.git_branch.len);
    @memcpy(self.git_branch[0..len], branch[0..len]);
    self.git_branch_len = @intCast(len);
}

/// Get the git branch as a slice.
pub fn getGitBranch(self: *const SidebarTab) []const u8 {
    return self.git_branch[0..self.git_branch_len];
}

/// Set the last notification text.
pub fn setLastNotification(self: *SidebarTab, text: []const u8) void {
    const len = @min(text.len, self.last_notification.len);
    @memcpy(self.last_notification[0..len], text[0..len]);
    self.last_notification_len = @intCast(len);
}

/// Add a notification (increments unread count and updates text).
pub fn addNotification(self: *SidebarTab, text: []const u8) void {
    self.setLastNotification(text);
    self.unread_count +|= 1;
}

/// Mark all notifications as read.
pub fn markRead(self: *SidebarTab) void {
    self.unread_count = 0;
}

/// Add a listening port.
pub fn addPort(self: *SidebarTab, port: u16) void {
    if (self.port_count < self.ports.len) {
        self.ports[self.port_count] = port;
        self.port_count += 1;
    }
}

/// Clear all ports.
pub fn clearPorts(self: *SidebarTab) void {
    self.port_count = 0;
}

/// Deinitialize (no-op for stack-allocated fixed buffers, but needed for interface).
pub fn deinit(self: *SidebarTab, allocator: Allocator) void {
    _ = self;
    _ = allocator;
}
