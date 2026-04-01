const std = @import("std");
const Allocator = std.mem.Allocator;

/// Ring buffer of recent notifications, organized per workspace.
/// Supports mark-as-read and jump-to-latest-unread.
pub const NotificationStore = struct {
    allocator: Allocator,
    entries: [MAX_ENTRIES]Entry = [_]Entry{.{}} ** MAX_ENTRIES,
    head: usize = 0,
    count: usize = 0,
    total_unread: usize = 0,

    pub const MAX_ENTRIES = 256;

    pub const Entry = struct {
        workspace_id: u32 = 0,
        timestamp: i64 = 0,
        title: [128]u8 = [_]u8{0} ** 128,
        title_len: u8 = 0,
        body: [256]u8 = [_]u8{0} ** 256,
        body_len: u16 = 0,
        is_read: bool = true,

        pub fn getTitle(self: *const Entry) []const u8 {
            return self.title[0..self.title_len];
        }

        pub fn getBody(self: *const Entry) []const u8 {
            return self.body[0..self.body_len];
        }
    };

    pub fn init(allocator: Allocator) NotificationStore {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *NotificationStore) void {
        _ = self;
    }

    /// Add a notification. Returns the index in the ring buffer.
    pub fn add(
        self: *NotificationStore,
        workspace_id: u32,
        title: []const u8,
        body: []const u8,
    ) usize {
        const idx = (self.head + self.count) % MAX_ENTRIES;

        var entry = &self.entries[idx];
        entry.workspace_id = workspace_id;
        entry.timestamp = std.time.timestamp();
        entry.is_read = false;

        const tl = @min(title.len, entry.title.len);
        @memcpy(entry.title[0..tl], title[0..tl]);
        entry.title_len = @intCast(tl);

        const bl = @min(body.len, entry.body.len);
        @memcpy(entry.body[0..bl], body[0..bl]);
        entry.body_len = @intCast(bl);

        if (self.count < MAX_ENTRIES) {
            self.count += 1;
        } else {
            // Overwriting oldest — if it was unread, adjust count
            self.head = (self.head + 1) % MAX_ENTRIES;
        }

        self.total_unread += 1;
        return idx;
    }

    /// Mark a notification as read.
    pub fn markRead(self: *NotificationStore, idx: usize) void {
        if (idx >= MAX_ENTRIES) return;
        if (!self.entries[idx].is_read) {
            self.entries[idx].is_read = true;
            self.total_unread -|= 1;
        }
    }

    /// Mark all notifications for a workspace as read.
    pub fn markAllRead(self: *NotificationStore, workspace_id: u32) void {
        for (&self.entries) |*entry| {
            if (entry.workspace_id == workspace_id and !entry.is_read) {
                entry.is_read = true;
                self.total_unread -|= 1;
            }
        }
    }

    /// Find the latest unread notification (any workspace).
    pub fn findLatestUnread(self: *const NotificationStore) ?usize {
        if (self.count == 0) return null;

        var i = self.count;
        while (i > 0) {
            i -= 1;
            const idx = (self.head + i) % MAX_ENTRIES;
            if (!self.entries[idx].is_read) return idx;
        }
        return null;
    }

    /// Find the latest unread notification for a specific workspace.
    pub fn findLatestUnreadForWorkspace(self: *const NotificationStore, workspace_id: u32) ?usize {
        if (self.count == 0) return null;

        var i = self.count;
        while (i > 0) {
            i -= 1;
            const idx = (self.head + i) % MAX_ENTRIES;
            if (self.entries[idx].workspace_id == workspace_id and !self.entries[idx].is_read) {
                return idx;
            }
        }
        return null;
    }

    /// Count unread notifications for a specific workspace.
    pub fn unreadCountForWorkspace(self: *const NotificationStore, workspace_id: u32) usize {
        var count: usize = 0;
        for (0..self.count) |i| {
            const idx = (self.head + i) % MAX_ENTRIES;
            if (self.entries[idx].workspace_id == workspace_id and !self.entries[idx].is_read) {
                count += 1;
            }
        }
        return count;
    }

    /// Get a notification entry by index.
    pub fn get(self: *const NotificationStore, idx: usize) ?*const Entry {
        if (idx >= MAX_ENTRIES) return null;
        if (self.entries[idx].timestamp == 0) return null;
        return &self.entries[idx];
    }

    /// Iterate over all notifications (newest first).
    pub fn iterNewest(self: *const NotificationStore) Iterator {
        return .{
            .store = self,
            .remaining = self.count,
        };
    }

    pub const Iterator = struct {
        store: *const NotificationStore,
        remaining: usize,

        pub fn next(self: *Iterator) ?*const Entry {
            if (self.remaining == 0) return null;
            self.remaining -= 1;
            const idx = (self.store.head + self.remaining) % MAX_ENTRIES;
            return &self.store.entries[idx];
        }
    };
};

test "NotificationStore: add and read" {
    var store = NotificationStore.init(std.testing.allocator);
    defer store.deinit();

    const idx = store.add(1, "Build", "Build succeeded");
    try std.testing.expect(!store.entries[idx].is_read);
    try std.testing.expectEqual(@as(usize, 1), store.total_unread);

    store.markRead(idx);
    try std.testing.expect(store.entries[idx].is_read);
    try std.testing.expectEqual(@as(usize, 0), store.total_unread);
}

test "NotificationStore: find unread" {
    var store = NotificationStore.init(std.testing.allocator);
    defer store.deinit();

    _ = store.add(1, "First", "");
    _ = store.add(2, "Second", "");
    const idx3 = store.add(1, "Third", "");

    const latest = store.findLatestUnread().?;
    try std.testing.expectEqual(idx3, latest);

    const ws1_latest = store.findLatestUnreadForWorkspace(1).?;
    try std.testing.expectEqual(idx3, ws1_latest);
}
