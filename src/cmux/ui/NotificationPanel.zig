const std = @import("std");
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;
const NotificationStore = @import("../notifications/NotificationStore.zig").NotificationStore;

/// A dropdown panel that displays the notification list for the active workspace.
/// It is anchored to the live Win32 window and backed directly by NotificationStore.
pub const NotificationPanel = struct {
    hwnd: ?w32.HWND = null,
    parent_hwnd: ?w32.HWND = null,
    store: ?*NotificationStore = null,
    theme: Theme = Theme.dark(),
    scale: f32 = 1.0,
    visible: bool = false,
    scroll_offset: i32 = 0,
    workspace_id: u32 = 0,

    pub const WINDOW_CLASS_NAME = "CmuxNotificationPanel";
    pub const PANEL_WIDTH: u32 = 320;
    pub const PANEL_MAX_HEIGHT: u32 = 480;
    pub const PANEL_MIN_HEIGHT: u32 = 120;
    pub const HEADER_HEIGHT: u32 = 36;
    pub const ENTRY_HEIGHT: u32 = 64;
    pub const ENTRY_GAP: u32 = 8;
    pub const PANEL_PADDING: u32 = 10;

    pub fn init() NotificationPanel {
        return .{};
    }

    pub fn deinit(self: *NotificationPanel) void {
        if (self.hwnd) |hwnd| {
            _ = w32.SetWindowLongPtrW(hwnd, w32.GWLP_USERDATA, 0);
            _ = w32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
    }

    pub fn setStore(self: *NotificationPanel, store: *NotificationStore) void {
        self.store = store;
    }

    pub fn setWorkspace(self: *NotificationPanel, workspace_id: u32) void {
        if (self.workspace_id != workspace_id) {
            self.workspace_id = workspace_id;
            self.scroll_offset = 0;
        }
    }

    pub fn isShowingWorkspace(self: *const NotificationPanel, workspace_id: u32) bool {
        return self.visible and self.workspace_id == workspace_id;
    }

    pub fn invalidate(self: *NotificationPanel) void {
        if (self.hwnd) |hwnd| {
            _ = w32.InvalidateRect(hwnd, null, 0);
        }
    }

    /// Show the panel for a workspace at a screen-space anchor position.
    pub fn showAt(self: *NotificationPanel, workspace_id: u32, x: i32, y: i32) void {
        self.setWorkspace(workspace_id);
        self.visible = true;
        self.reposition(x, y);
        if (self.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
            _ = w32.InvalidateRect(hwnd, null, 0);
            _ = w32.SetFocus(hwnd);
        }
    }

    /// Hide the panel.
    pub fn hide(self: *NotificationPanel) void {
        if (!self.visible) return;
        self.visible = false;
        if (self.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
        }
    }

    /// Toggle panel visibility for a workspace.
    pub fn toggleForWorkspace(self: *NotificationPanel, workspace_id: u32, x: i32, y: i32) void {
        if (self.isShowingWorkspace(workspace_id)) {
            self.hide();
            return;
        }
        self.showAt(workspace_id, x, y);
    }

    /// Register the panel window class.
    pub fn registerClass(hinstance: w32.HINSTANCE) !void {
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = w32.CS_HREDRAW | w32.CS_VREDRAW | w32.CS_DROPSHADOW,
            .lpfnWndProc = panelWndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = toWide(WINDOW_CLASS_NAME),
            .hIconSm = null,
        };

        _ = w32.RegisterClassExW(&wc);
    }

    /// Create the panel as a popup window.
    pub fn createWindow(self: *NotificationPanel, parent: w32.HWND, hinstance: w32.HINSTANCE, x: i32, y: i32) !void {
        self.parent_hwnd = parent;

        const dpi = w32.GetDpiForWindow(parent);
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;

        const width = Theme.scaled(PANEL_WIDTH, self.scale);
        const height = Theme.scaled(PANEL_MIN_HEIGHT, self.scale);

        self.hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_TOPMOST,
            toWide(WINDOW_CLASS_NAME),
            toWide("Notifications"),
            w32.WS_POPUP | w32.WS_BORDER,
            x,
            y,
            width,
            height,
            parent,
            null,
            hinstance,
            @intFromPtr(self),
        );

        if (self.hwnd == null) return error.CreateWindowFailed;
        _ = w32.SetWindowLongPtrW(self.hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        _ = w32.ShowWindow(self.hwnd.?, w32.SW_HIDE);
    }

    pub fn reposition(self: *NotificationPanel, x: i32, y: i32) void {
        const hwnd = self.hwnd orelse return;
        const width = Theme.scaled(PANEL_WIDTH, self.scale);
        const height = self.panelHeight();
        _ = w32.MoveWindow(hwnd, x, y, width, height, 1);
    }

    fn panelHeight(self: *NotificationPanel) i32 {
        const visible_entries = @max(self.matchingEntryCount(), 1);
        const content_height = Theme.scaled(HEADER_HEIGHT, self.scale) +
            Theme.scaled(PANEL_PADDING, self.scale) +
            @as(i32, @intCast(visible_entries)) * (Theme.scaled(ENTRY_HEIGHT, self.scale) + Theme.scaled(ENTRY_GAP, self.scale));
        return std.math.clamp(
            content_height,
            Theme.scaled(PANEL_MIN_HEIGHT, self.scale),
            Theme.scaled(PANEL_MAX_HEIGHT, self.scale),
        );
    }

    fn matchingEntryCount(self: *const NotificationPanel) usize {
        const store = self.store orelse return 0;
        var count: usize = 0;
        var it = store.iterNewest();
        while (it.next()) |entry| {
            if (self.matchesEntry(entry)) count += 1;
        }
        return count;
    }

    fn matchesEntry(self: *const NotificationPanel, entry: *const NotificationStore.Entry) bool {
        return entry.workspace_id == self.workspace_id or entry.workspace_id == 0;
    }

    fn visibleRowCount(self: *const NotificationPanel, client_height: i32) i32 {
        const entry_stride = Theme.scaled(ENTRY_HEIGHT, self.scale) + Theme.scaled(ENTRY_GAP, self.scale);
        if (entry_stride <= 0) return 1;
        const usable_height = client_height - Theme.scaled(HEADER_HEIGHT, self.scale) - Theme.scaled(PANEL_PADDING, self.scale);
        return @max(@divTrunc(@max(usable_height, entry_stride), entry_stride), 1);
    }

    fn clampScroll(self: *NotificationPanel) void {
        const hwnd = self.hwnd orelse {
            self.scroll_offset = @max(self.scroll_offset, 0);
            return;
        };
        var client_rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &client_rect) == 0) {
            self.scroll_offset = @max(self.scroll_offset, 0);
            return;
        }
        const total: i32 = @intCast(self.matchingEntryCount());
        const max_offset = @max(total - self.visibleRowCount(client_rect.bottom - client_rect.top), 0);
        self.scroll_offset = std.math.clamp(self.scroll_offset, 0, max_offset);
    }

    fn drawTextUtf8(
        self: *const NotificationPanel,
        hdc: w32.HDC,
        text: []const u8,
        rect: *w32.RECT,
        color: u32,
        format: u32,
    ) void {
        _ = self;
        if (text.len == 0) return;

        var wide_buf: [512]u16 = undefined;
        const len = std.unicode.utf8ToUtf16Le(&wide_buf, text) catch 0;
        if (len == 0) return;

        _ = w32.SetTextColor(hdc, color);
        _ = w32.DrawTextW(hdc, @ptrCast(&wide_buf), @intCast(len), rect, format);
    }

    fn paint(self: *NotificationPanel, hwnd: w32.HWND) void {
        var ps: w32.PAINTSTRUCT = undefined;
        const hdc = w32.BeginPaint(hwnd, &ps) orelse return;
        defer _ = w32.EndPaint(hwnd, &ps);

        var rect: w32.RECT = undefined;
        if (w32.GetClientRect(hwnd, &rect) == 0) return;

        const bg_brush = w32.CreateSolidBrush(self.theme.sidebar_bg.toColorRef()) orelse return;
        defer _ = w32.DeleteObject(bg_brush);
        _ = w32.FillRect(hdc, &rect, bg_brush);

        const header_h = Theme.scaled(HEADER_HEIGHT, self.scale);
        const padding = Theme.scaled(PANEL_PADDING, self.scale);
        const entry_h = Theme.scaled(ENTRY_HEIGHT, self.scale);
        const entry_gap = Theme.scaled(ENTRY_GAP, self.scale);

        const header_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(14.0 * self.scale))),
            0,
            0,
            0,
            w32.FW_BOLD,
            0,
            0,
            0,
            w32.DEFAULT_CHARSET,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
        const body_font = w32.CreateFontW(
            -@as(i32, @intFromFloat(@round(12.0 * self.scale))),
            0,
            0,
            0,
            w32.FW_NORMAL,
            0,
            0,
            0,
            w32.DEFAULT_CHARSET,
            0,
            0,
            0,
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
        );
        defer {
            if (header_font) |font| _ = w32.DeleteObject(font);
            if (body_font) |font| _ = w32.DeleteObject(font);
        }

        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);

        if (header_font) |font| {
            _ = w32.SelectObject(hdc, font);
        }

        var header_rect = w32.RECT{
            .left = padding,
            .top = padding,
            .right = rect.right - padding,
            .bottom = header_h,
        };
        self.drawTextUtf8(
            hdc,
            "Notifications",
            &header_rect,
            self.theme.sidebar_text.toColorRef(),
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );

        if (body_font) |font| {
            _ = w32.SelectObject(hdc, font);
        }

        const store = self.store;
        const total_matches = self.matchingEntryCount();
        self.clampScroll();

        if (store == null or total_matches == 0) {
            var empty_rect = w32.RECT{
                .left = padding,
                .top = header_h + padding,
                .right = rect.right - padding,
                .bottom = rect.bottom - padding,
            };
            self.drawTextUtf8(
                hdc,
                "No notifications for this workspace yet.",
                &empty_rect,
                self.theme.sidebar_text_dim.toColorRef(),
                w32.DT_LEFT | w32.DT_NOPREFIX,
            );
            return;
        }

        var y = header_h + padding;
        var skipped: i32 = 0;
        var drawn: i32 = 0;
        const max_rows = self.visibleRowCount(rect.bottom - rect.top);

        var it = store.?.iterNewest();
        while (it.next()) |entry| {
            if (!self.matchesEntry(entry)) continue;
            if (skipped < self.scroll_offset) {
                skipped += 1;
                continue;
            }
            if (drawn >= max_rows) break;

            var entry_rect = w32.RECT{
                .left = padding,
                .top = y,
                .right = rect.right - padding,
                .bottom = y + entry_h,
            };

            const entry_brush = w32.CreateSolidBrush(
                if (entry.is_read) self.theme.sidebar_tab_bg.toColorRef() else self.theme.sidebar_tab_active_bg.toColorRef(),
            );
            if (entry_brush) |brush| {
                _ = w32.FillRect(hdc, &entry_rect, brush);
                _ = w32.DeleteObject(brush);
            }

            const divider_brush = w32.CreateSolidBrush(self.theme.sidebar_separator.toColorRef());
            if (divider_brush) |brush| {
                var divider_rect = w32.RECT{
                    .left = entry_rect.left,
                    .top = entry_rect.bottom - 1,
                    .right = entry_rect.right,
                    .bottom = entry_rect.bottom,
                };
                _ = w32.FillRect(hdc, &divider_rect, brush);
                _ = w32.DeleteObject(brush);
            }

            if (!entry.is_read) {
                const dot_size = Theme.scaled(8, self.scale);
                const dot_brush = w32.CreateSolidBrush(self.theme.unread_dot.toColorRef());
                if (dot_brush) |brush| {
                    var dot_rect = w32.RECT{
                        .left = entry_rect.left + padding,
                        .top = entry_rect.top + padding,
                        .right = entry_rect.left + padding + dot_size,
                        .bottom = entry_rect.top + padding + dot_size,
                    };
                    _ = w32.FillRect(hdc, &dot_rect, brush);
                    _ = w32.DeleteObject(brush);
                }
            }

            var title_rect = w32.RECT{
                .left = entry_rect.left + padding + Theme.scaled(14, self.scale),
                .top = entry_rect.top + padding - 2,
                .right = entry_rect.right - padding,
                .bottom = entry_rect.top + padding + Theme.scaled(18, self.scale),
            };
            const title = if (entry.getTitle().len > 0) entry.getTitle() else "Notification";
            self.drawTextUtf8(
                hdc,
                title,
                &title_rect,
                self.theme.sidebar_text.toColorRef(),
                w32.DT_LEFT | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );

            var body_rect = w32.RECT{
                .left = entry_rect.left + padding + Theme.scaled(14, self.scale),
                .top = entry_rect.top + padding + Theme.scaled(18, self.scale),
                .right = entry_rect.right - padding,
                .bottom = entry_rect.bottom - padding,
            };
            const body = if (entry.getBody().len > 0) entry.getBody() else "(no body)";
            self.drawTextUtf8(
                hdc,
                body,
                &body_rect,
                self.theme.sidebar_text_dim.toColorRef(),
                w32.DT_LEFT | w32.DT_NOPREFIX,
            );

            y += entry_h + entry_gap;
            drawn += 1;
        }
    }

    fn panelWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.C) isize {
        const self = getPanelPtr(hwnd) orelse return w32.DefWindowProcW(hwnd, msg, wparam, lparam);

        switch (msg) {
            w32.WM_PAINT => {
                self.paint(hwnd);
                return 0;
            },
            w32.WM_KILLFOCUS => {
                self.hide();
                return 0;
            },
            w32.WM_KEYDOWN => {
                const vk: u16 = @intCast(wparam & 0xFFFF);
                if (vk == w32.VK_ESCAPE) {
                    self.hide();
                    return 0;
                }
                if (vk == 'I' and w32.GetKeyState(w32.VK_CONTROL) < 0) {
                    self.hide();
                    return 0;
                }
            },
            w32.WM_MOUSEWHEEL => {
                const delta: i16 = @truncate(@as(u32, @bitCast(@as(i32, @truncate(wparam >> 16)))));
                self.scroll_offset += if (delta > 0) -1 else 1;
                self.clampScroll();
                self.invalidate();
                return 0;
            },
            w32.WM_SIZE => {
                self.clampScroll();
                self.invalidate();
                return 0;
            },
            w32.WM_ERASEBKGND => return 1,
            else => {},
        }
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    fn getPanelPtr(hwnd: w32.HWND) ?*NotificationPanel {
        const ptr = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(ptr)));
    }

    fn toWide(comptime s: []const u8) [*:0]const u16 {
        comptime {
            var buf: [s.len + 1]u16 = undefined;
            for (s, 0..) |c, i| {
                buf[i] = c;
            }
            buf[s.len] = 0;
            return &buf;
        }
    }
};
