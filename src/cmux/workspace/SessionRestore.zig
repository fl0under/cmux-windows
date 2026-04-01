const std = @import("std");
const Allocator = std.mem.Allocator;
const Workspace = @import("Workspace.zig").Workspace;
const WorkspaceManager = @import("WorkspaceManager.zig").WorkspaceManager;

/// Persists workspace layout and metadata to a JSON file for session restore.
/// Saved to %LOCALAPPDATA%\cmux\session.json.
pub const SessionRestore = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) SessionRestore {
        return .{ .allocator = allocator };
    }

    /// Get the session file path.
    pub fn getSessionPath(self: *SessionRestore) ![]u8 {
        // Use %LOCALAPPDATA%\cmux\session.json
        const local_app_data = std.process.getEnvVarOwned(self.allocator, "LOCALAPPDATA") catch {
            return error.NoLocalAppData;
        };
        defer self.allocator.free(local_app_data);

        return std.fmt.allocPrint(self.allocator, "{s}\\cmux\\session.json", .{local_app_data});
    }

    /// Save all workspace state to the session file.
    pub fn save(self: *SessionRestore, manager: *const WorkspaceManager) !void {
        const path = try self.getSessionPath();
        defer self.allocator.free(path);

        // Ensure directory exists
        if (std.mem.lastIndexOf(u8, path, "\\")) |sep| {
            std.fs.cwd().makePath(path[0..sep]) catch {};
        }

        var file = try std.fs.cwd().createFile(path, .{});
        defer file.close();

        var buffered = std.io.bufferedWriter(file.writer());
        var writer = std.json.writeStream(buffered.writer(), .{});

        try writer.beginObject();

        try writer.objectField("version");
        try writer.write(@as(u32, 1));

        try writer.objectField("active_index");
        try writer.write(manager.active_index);

        try writer.objectField("default_shell");
        try writer.write(manager.default_shell[0..manager.default_shell_len]);

        try writer.objectField("workspaces");
        try writer.beginArray();
        for (manager.workspaces.items) |ws| {
            try ws.toJson(&writer);
        }
        try writer.endArray();

        try writer.endObject();
        try buffered.flush();
    }

    /// Load workspace state from the session file.
    /// Returns the number of workspaces restored.
    pub fn load(self: *SessionRestore, manager: *WorkspaceManager) !usize {
        const path = try self.getSessionPath();
        defer self.allocator.free(path);

        const file = std.fs.cwd().openFile(path, .{}) catch {
            return 0; // No session file — first launch
        };
        defer file.close();

        const contents = try file.readToEndAlloc(self.allocator, 1024 * 1024); // 1MB max
        defer self.allocator.free(contents);

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, contents, .{}) catch {
            return 0; // Corrupted session file
        };
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return 0;

        // Restore default shell
        if (root.object.get("default_shell")) |shell| {
            if (shell == .string) {
                manager.setDefaultShell(shell.string);
            }
        }

        // Restore workspaces
        var count: usize = 0;
        if (root.object.get("workspaces")) |workspaces| {
            if (workspaces == .array) {
                for (workspaces.array.items) |ws_value| {
                    if (ws_value != .object) continue;

                    const name = if (ws_value.object.get("name")) |n|
                        (if (n == .string) n.string else null)
                    else
                        null;

                    const shell = if (ws_value.object.get("shell_command")) |s|
                        (if (s == .string) s.string else null)
                    else
                        null;

                    const ws = manager.createWorkspace(name, shell) catch continue;

                    // Restore CWD
                    if (ws_value.object.get("cwd")) |cwd| {
                        if (cwd == .string) {
                            ws.setCwd(cwd.string);
                        }
                    }

                    count += 1;
                }
            }
        }

        // Restore active index
        if (root.object.get("active_index")) |idx| {
            if (idx == .integer) {
                const i: usize = @intCast(idx.integer);
                if (i < manager.workspaces.items.len) {
                    manager.switchTo(i);
                }
            }
        }

        return count;
    }
};
