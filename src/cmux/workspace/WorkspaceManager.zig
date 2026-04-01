const std = @import("std");
const Allocator = std.mem.Allocator;
const Workspace = @import("Workspace.zig").Workspace;
const Sidebar = @import("../ui/Sidebar.zig").Sidebar;

/// Manages the lifecycle of all workspaces: creation, destruction, switching,
/// and persistence. Coordinates between the sidebar UI and the terminal surfaces.
pub const WorkspaceManager = struct {
    allocator: Allocator,
    workspaces: std.ArrayList(*Workspace),
    active_index: usize = 0,
    next_id: u32 = 1,
    sidebar: ?*Sidebar = null,

    /// Default shell command (from config).
    default_shell: [256]u8 = [_]u8{0} ** 256,
    default_shell_len: u16 = 0,

    /// Callback for when a workspace is created and needs a terminal surface.
    on_workspace_created: ?*const fn (ws: *Workspace) void = null,
    /// Callback for when the active workspace changes.
    on_workspace_switched: ?*const fn (old: ?*Workspace, new: *Workspace) void = null,
    /// Callback for when a workspace is about to be destroyed.
    on_workspace_closing: ?*const fn (ws: *Workspace) void = null,

    pub fn init(allocator: Allocator) WorkspaceManager {
        return .{
            .allocator = allocator,
            .workspaces = std.ArrayList(*Workspace).init(allocator),
        };
    }

    pub fn deinit(self: *WorkspaceManager) void {
        for (self.workspaces.items) |ws| {
            ws.deinit();
            self.allocator.destroy(ws);
        }
        self.workspaces.deinit();
    }

    /// Set the default shell command (from configuration).
    pub fn setDefaultShell(self: *WorkspaceManager, cmd: []const u8) void {
        const len = @min(cmd.len, self.default_shell.len);
        @memcpy(self.default_shell[0..len], cmd[0..len]);
        self.default_shell_len = @intCast(len);
    }

    /// Create a new workspace with an optional name and shell override.
    pub fn createWorkspace(self: *WorkspaceManager, name: ?[]const u8, shell: ?[]const u8) !*Workspace {
        const id = self.next_id;
        self.next_id += 1;

        // Generate default name if none provided
        var name_buf: [32]u8 = undefined;
        const ws_name = name orelse blk: {
            const len = std.fmt.bufPrint(&name_buf, "Workspace {d}", .{id}) catch "Workspace";
            break :blk len;
        };

        const ws = try self.allocator.create(Workspace);
        ws.* = Workspace.init(self.allocator, id, ws_name);

        // Set shell command
        const shell_cmd = shell orelse self.default_shell[0..self.default_shell_len];
        if (shell_cmd.len > 0) {
            ws.setShellCommand(shell_cmd);
        }

        try self.workspaces.append(ws);

        // Add tab to sidebar
        if (self.sidebar) |sb| {
            _ = sb.addTab(ws_name) catch {};
        }

        // Fire callback
        if (self.on_workspace_created) |cb| {
            cb(ws);
        }

        return ws;
    }

    /// Switch to a workspace by index.
    pub fn switchTo(self: *WorkspaceManager, index: usize) void {
        if (index >= self.workspaces.items.len) return;
        if (index == self.active_index) return;

        const old = self.getActive();
        if (old) |o| o.is_active = false;

        self.active_index = index;
        const new = self.workspaces.items[index];
        new.is_active = true;

        // Update sidebar
        if (self.sidebar) |sb| {
            sb.setActiveTab(index);
        }

        // Fire callback
        if (self.on_workspace_switched) |cb| {
            cb(old, new);
        }
    }

    /// Close a workspace by index.
    pub fn closeWorkspace(self: *WorkspaceManager, index: usize) void {
        if (index >= self.workspaces.items.len) return;
        if (self.workspaces.items.len <= 1) return; // Don't close the last workspace

        const ws = self.workspaces.items[index];

        // Fire callback before destruction
        if (self.on_workspace_closing) |cb| {
            cb(ws);
        }

        // Remove from sidebar
        if (self.sidebar) |sb| {
            sb.removeTab(index);
        }

        _ = self.workspaces.orderedRemove(index);
        ws.deinit();
        self.allocator.destroy(ws);

        // Adjust active index
        if (self.active_index >= self.workspaces.items.len) {
            self.active_index = self.workspaces.items.len - 1;
        }

        // Switch to new active
        if (self.workspaces.items.len > 0) {
            self.workspaces.items[self.active_index].is_active = true;
            if (self.sidebar) |sb| {
                sb.setActiveTab(self.active_index);
            }
        }
    }

    /// Get the currently active workspace.
    pub fn getActive(self: *WorkspaceManager) ?*Workspace {
        if (self.workspaces.items.len == 0) return null;
        return self.workspaces.items[self.active_index];
    }

    /// Get a workspace by index.
    pub fn get(self: *WorkspaceManager, index: usize) ?*Workspace {
        if (index >= self.workspaces.items.len) return null;
        return self.workspaces.items[index];
    }

    /// Get total workspace count.
    pub fn count(self: *const WorkspaceManager) usize {
        return self.workspaces.items.len;
    }

    /// Rename a workspace.
    pub fn rename(self: *WorkspaceManager, index: usize, new_name: []const u8) void {
        if (index >= self.workspaces.items.len) return;
        self.workspaces.items[index].setName(new_name);
        if (self.sidebar) |sb| {
            var tab = self.workspaces.items[index].tab_meta;
            sb.updateTab(index, tab);
        }
    }

    /// Move a workspace from one position to another (for drag reordering).
    pub fn reorder(self: *WorkspaceManager, from: usize, to: usize) void {
        if (from >= self.workspaces.items.len or to >= self.workspaces.items.len) return;
        if (from == to) return;

        const ws = self.workspaces.orderedRemove(from);
        self.workspaces.insert(to, ws) catch return;

        // Adjust active index
        if (self.active_index == from) {
            self.active_index = to;
        } else if (from < self.active_index and to >= self.active_index) {
            self.active_index -= 1;
        } else if (from > self.active_index and to <= self.active_index) {
            self.active_index += 1;
        }
    }

    /// Find workspace by ID.
    pub fn findById(self: *WorkspaceManager, id: u32) ?struct { index: usize, workspace: *Workspace } {
        for (self.workspaces.items, 0..) |ws, i| {
            if (ws.id == id) return .{ .index = i, .workspace = ws };
        }
        return null;
    }
};
