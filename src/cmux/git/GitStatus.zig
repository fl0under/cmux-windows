const std = @import("std");
const Allocator = std.mem.Allocator;
const ShellDetect = @import("ShellDetect.zig");

/// Queries git status (branch, PR info) for a workspace.
/// Routes commands through the correct executable based on shell type:
///   - Native shells: git.exe
///   - WSL shells: wsl.exe git
pub const GitStatus = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) GitStatus {
        return .{ .allocator = allocator };
    }

    /// Get the current git branch for a workspace directory.
    /// For WSL workspaces, routes through `wsl.exe git`.
    pub fn getBranch(self: *GitStatus, cwd: []const u8, is_wsl: bool) ![]u8 {
        const result = if (is_wsl)
            try self.runCommand(&.{ "wsl.exe", "git", "rev-parse", "--abbrev-ref", "HEAD" }, cwd)
        else
            try self.runCommand(&.{ "git", "rev-parse", "--abbrev-ref", "HEAD" }, cwd);

        return result;
    }

    /// Get PR status using GitHub CLI.
    /// Returns JSON: {"number": 123, "state": "OPEN", "title": "..."}
    pub fn getPrStatus(self: *GitStatus, cwd: []const u8, is_wsl: bool) ![]u8 {
        const result = if (is_wsl)
            try self.runCommand(&.{ "wsl.exe", "gh", "pr", "view", "--json", "number,state,title" }, cwd)
        else
            try self.runCommand(&.{ "gh", "pr", "view", "--json", "number,state,title" }, cwd);

        return result;
    }

    /// Get a short status summary (clean, dirty, untracked count).
    pub fn getShortStatus(self: *GitStatus, cwd: []const u8, is_wsl: bool) ![]u8 {
        const result = if (is_wsl)
            try self.runCommand(&.{ "wsl.exe", "git", "status", "--porcelain" }, cwd)
        else
            try self.runCommand(&.{ "git", "status", "--porcelain" }, cwd);

        return result;
    }

    fn runCommand(self: *GitStatus, argv: []const []const u8, cwd: []const u8) ![]u8 {
        var child = std.process.Child.init(argv, self.allocator);

        // Set working directory if provided and not empty
        if (cwd.len > 0) {
            child.cwd = cwd;
        }

        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;

        try child.spawn();
        const stdout = try child.stdout.?.readToEndAlloc(self.allocator, 4096);
        const term = try child.wait();

        if (term.Exited != 0) {
            self.allocator.free(stdout);
            return error.CommandFailed;
        }

        // Trim trailing newline
        const trimmed = std.mem.trimRight(u8, stdout, "\r\n");
        if (trimmed.len < stdout.len) {
            const result = try self.allocator.dupe(u8, trimmed);
            self.allocator.free(stdout);
            return result;
        }
        return stdout;
    }
};
