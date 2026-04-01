const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;

/// Binary tree split pane manager. Each leaf node hosts either a terminal
/// surface or a browser pane. Internal nodes are horizontal or vertical splits
/// with a draggable divider.
///
/// Layout:
///         VSplit(0.5)
///        /           \
///   Surface1      HSplit(0.6)
///                 /         \
///            Surface2    BrowserPane
///
pub const SplitContainer = struct {
    allocator: Allocator,
    root: ?*Node = null,
    focused_leaf: ?*Node = null,
    scale: f32 = 1.0,

    // Divider drag state
    drag_node: ?*Node = null,
    drag_start: i32 = 0,

    pub const Direction = enum {
        horizontal, // Split top/bottom
        vertical, // Split left/right
    };

    /// The type of content a leaf node hosts.
    pub const PaneType = enum {
        terminal,
        browser,
    };

    pub const Node = struct {
        /// Parent in the split tree (null for root).
        parent: ?*Node = null,

        data: union(enum) {
            /// Internal split node.
            split: SplitData,
            /// Leaf node hosting a pane.
            leaf: LeafData,
        },

        pub const SplitData = struct {
            direction: Direction,
            /// Split ratio (0.0 to 1.0), position of divider.
            ratio: f32 = 0.5,
            first: *Node,
            second: *Node,
            /// The HWND container for this split level.
            hwnd: ?w32.HWND = null,
        };

        pub const LeafData = struct {
            pane_type: PaneType,
            /// Opaque pointer to the hosted Surface or WebView.
            pane: ?*anyopaque = null,
            /// The HWND of the hosted content.
            hwnd: ?w32.HWND = null,
            /// Whether this leaf has the notification ring active.
            notification_ring: bool = false,
        };

        /// Check if this node is a leaf.
        pub fn isLeaf(self: *const Node) bool {
            return switch (self.data) {
                .leaf => true,
                .split => false,
            };
        }
    };

    pub fn init(allocator: Allocator) SplitContainer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SplitContainer) void {
        if (self.root) |root| {
            self.freeNode(root);
            self.root = null;
        }
        self.focused_leaf = null;
    }

    /// Create the initial single-pane root.
    pub fn createRoot(self: *SplitContainer, pane_type: PaneType, pane: ?*anyopaque, hwnd: ?w32.HWND) !*Node {
        const node = try self.allocator.create(Node);
        node.* = .{
            .data = .{ .leaf = .{
                .pane_type = pane_type,
                .pane = pane,
                .hwnd = hwnd,
            } },
        };
        self.root = node;
        self.focused_leaf = node;
        return node;
    }

    /// Split the focused leaf node in the given direction.
    /// Returns the new leaf node that was created.
    pub fn splitFocused(self: *SplitContainer, direction: Direction, pane_type: PaneType, pane: ?*anyopaque, hwnd: ?w32.HWND) !?*Node {
        const focused = self.focused_leaf orelse return null;
        return try self.splitNode(focused, direction, pane_type, pane, hwnd);
    }

    /// Split a specific leaf node, turning it into an internal split node.
    pub fn splitNode(
        self: *SplitContainer,
        leaf: *Node,
        direction: Direction,
        pane_type: PaneType,
        pane: ?*anyopaque,
        hwnd: ?w32.HWND,
    ) !*Node {
        // The existing leaf becomes the first child
        const existing_leaf = try self.allocator.create(Node);
        existing_leaf.* = leaf.*;

        // Create the new leaf (second child)
        const new_leaf = try self.allocator.create(Node);
        new_leaf.* = .{
            .data = .{ .leaf = .{
                .pane_type = pane_type,
                .pane = pane,
                .hwnd = hwnd,
            } },
        };

        // Convert the original node into a split node
        leaf.data = .{ .split = .{
            .direction = direction,
            .ratio = 0.5,
            .first = existing_leaf,
            .second = new_leaf,
        } };

        existing_leaf.parent = leaf;
        new_leaf.parent = leaf;

        // Focus the new pane
        self.focused_leaf = new_leaf;

        return new_leaf;
    }

    /// Close the focused leaf and collapse the tree.
    pub fn closeFocused(self: *SplitContainer) ?*anyopaque {
        const focused = self.focused_leaf orelse return null;
        return self.closeLeaf(focused);
    }

    /// Close a specific leaf node. Returns the pane pointer for cleanup.
    pub fn closeLeaf(self: *SplitContainer, leaf: *Node) ?*anyopaque {
        const pane = switch (leaf.data) {
            .leaf => |l| l.pane,
            .split => return null,
        };

        const parent = leaf.parent orelse {
            // This is the root and only node
            self.allocator.destroy(leaf);
            self.root = null;
            self.focused_leaf = null;
            return pane;
        };

        // Find the sibling
        const sibling = switch (parent.data) {
            .split => |s| if (s.first == leaf) s.second else s.first,
            .leaf => return null,
        };

        // Replace parent with sibling
        parent.data = sibling.data;
        switch (parent.data) {
            .split => |*s| {
                s.first.parent = parent;
                s.second.parent = parent;
            },
            .leaf => {},
        }

        // Update focus to the promoted sibling (or its leftmost leaf)
        self.focused_leaf = self.findLeftmostLeaf(parent);

        self.allocator.destroy(sibling);
        self.allocator.destroy(leaf);

        return pane;
    }

    /// Move focus directionally (up/down/left/right).
    pub fn moveFocus(self: *SplitContainer, dir: FocusDirection) void {
        const focused = self.focused_leaf orelse return;
        if (self.findAdjacentLeaf(focused, dir)) |adjacent| {
            self.focused_leaf = adjacent;
        }
    }

    pub const FocusDirection = enum {
        up,
        down,
        left,
        right,
    };

    /// Layout all nodes within the given rectangle (called on WM_SIZE).
    pub fn layout(self: *SplitContainer, rect: w32.RECT) void {
        if (self.root) |root| {
            self.layoutNode(root, rect);
        }
    }

    fn layoutNode(self: *SplitContainer, node: *Node, rect: w32.RECT) void {
        switch (node.data) {
            .leaf => |leaf| {
                if (leaf.hwnd) |hwnd| {
                    _ = w32.MoveWindow(
                        hwnd,
                        rect.left,
                        rect.top,
                        rect.right - rect.left,
                        rect.bottom - rect.top,
                        1,
                    );
                }
            },
            .split => |split| {
                const divider = Theme.scaled(Theme.split_divider_width, self.scale);
                const total_w = rect.right - rect.left;
                const total_h = rect.bottom - rect.top;

                var first_rect = rect;
                var second_rect = rect;

                switch (split.direction) {
                    .vertical => {
                        const split_pos = rect.left + @as(i32, @intFromFloat(@as(f32, @floatFromInt(total_w)) * split.ratio));
                        first_rect.right = split_pos;
                        second_rect.left = split_pos + divider;
                    },
                    .horizontal => {
                        const split_pos = rect.top + @as(i32, @intFromFloat(@as(f32, @floatFromInt(total_h)) * split.ratio));
                        first_rect.bottom = split_pos;
                        second_rect.top = split_pos + divider;
                    },
                }

                self.layoutNode(split.first, first_rect);
                self.layoutNode(split.second, second_rect);
            },
        }
    }

    /// Find the leftmost leaf in a subtree.
    fn findLeftmostLeaf(self: *SplitContainer, node: *Node) *Node {
        _ = self;
        var current = node;
        while (true) {
            switch (current.data) {
                .leaf => return current,
                .split => |s| current = s.first,
            }
        }
    }

    /// Find an adjacent leaf node in the given direction.
    fn findAdjacentLeaf(self: *SplitContainer, node: *Node, dir: FocusDirection) ?*Node {
        // Walk up the tree until we find a split in the matching direction
        // where we're on the opposite side, then walk down the other branch.
        var current = node;
        while (current.parent) |parent| {
            switch (parent.data) {
                .split => |s| {
                    const matches_dir = switch (dir) {
                        .left, .right => s.direction == .vertical,
                        .up, .down => s.direction == .horizontal,
                    };

                    if (matches_dir) {
                        const is_first = (s.first == current);
                        const want_second = (dir == .right or dir == .down);

                        if (is_first and want_second) {
                            return self.findLeftmostLeaf(s.second);
                        } else if (!is_first and !want_second) {
                            return self.findRightmostLeaf(s.first);
                        }
                    }
                },
                .leaf => {},
            }
            current = parent;
        }
        return null;
    }

    /// Find the rightmost leaf in a subtree.
    fn findRightmostLeaf(self: *SplitContainer, node: *Node) *Node {
        _ = self;
        var current = node;
        while (true) {
            switch (current.data) {
                .leaf => return current,
                .split => |s| current = s.second,
            }
        }
    }

    /// Free a node and all its children recursively.
    fn freeNode(self: *SplitContainer, node: *Node) void {
        switch (node.data) {
            .split => |s| {
                self.freeNode(s.first);
                self.freeNode(s.second);
            },
            .leaf => {},
        }
        self.allocator.destroy(node);
    }

    /// Count total leaf nodes.
    pub fn leafCount(self: *SplitContainer) usize {
        if (self.root) |root| {
            return countLeaves(root);
        }
        return 0;
    }

    fn countLeaves(node: *Node) usize {
        return switch (node.data) {
            .leaf => 1,
            .split => |s| countLeaves(s.first) + countLeaves(s.second),
        };
    }
};
