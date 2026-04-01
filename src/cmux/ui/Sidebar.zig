const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;
const SidebarTab = @import("SidebarTab.zig");

/// The vertical sidebar for cmux-windows. Renders as a child HWND on the left
/// edge of the main window using Direct2D. Displays workspace tabs with
/// metadata (name, shell type, git branch, notifications, ports).
pub const Sidebar = struct {
    allocator: Allocator,
    hwnd: ?w32.HWND = null,
    parent_hwnd: ?w32.HWND = null,
    theme: Theme = Theme.dark(),
    visible: bool = true,
    width: u32 = Theme.sidebar_width,
    scale: f32 = 1.0,

    // Tab state
    tabs: std.ArrayList(SidebarTab),
    active_tab: usize = 0,
    hovered_tab: ?usize = null,
    scroll_offset: i32 = 0,

    // Drag state
    dragging_tab: ?usize = null,
    drag_start_y: i32 = 0,
    drag_current_y: i32 = 0,
    tracking_mouse: bool = false,

    // Direct2D resources (opaque pointers, initialized on WM_CREATE)
    d2d_factory: ?*anyopaque = null,
    render_target: ?*anyopaque = null,
    dwrite_factory: ?*anyopaque = null,

    pub const WINDOW_CLASS_NAME = "CmuxSidebar";

    /// Window class registration constants.
    pub const WM_CMUX_TAB_CLICKED = w32.WM_USER + 100;
    pub const WM_CMUX_TAB_CLOSE = w32.WM_USER + 101;
    pub const WM_CMUX_NEW_WORKSPACE = w32.WM_USER + 102;
    pub const WM_CMUX_TAB_REORDER = w32.WM_USER + 103;
    pub const WM_CMUX_TAB_RENAME = w32.WM_USER + 104;
    pub const WM_CMUX_TAB_CONTEXT = w32.WM_USER + 105;

    pub fn init(allocator: Allocator) Sidebar {
        return .{
            .allocator = allocator,
            .tabs = std.ArrayList(SidebarTab).init(allocator),
        };
    }

    pub fn deinit(self: *Sidebar) void {
        self.destroyD2DResources();
        if (self.hwnd) |hwnd| {
            _ = w32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
        for (self.tabs.items) |*tab| {
            tab.deinit(self.allocator);
        }
        self.tabs.deinit();
    }

    /// Create the sidebar child window inside the given parent.
    pub fn createWindow(self: *Sidebar, parent: w32.HWND, hinstance: w32.HINSTANCE) !void {
        self.parent_hwnd = parent;

        // Get parent DPI for scaling
        const dpi = w32.GetDpiForWindow(parent);
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;

        const scaled_width = Theme.scaled(self.width, self.scale);

        var rect: w32.RECT = undefined;
        _ = w32.GetClientRect(parent, &rect);

        self.hwnd = w32.CreateWindowExW(
            0, // dwExStyle
            toWide(WINDOW_CLASS_NAME),
            null, // lpWindowName
            w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPCHILDREN,
            0, // x
            0, // y
            scaled_width,
            rect.bottom - rect.top,
            parent,
            null, // hMenu
            hinstance,
            @intFromPtr(self), // lpParam → CREATESTRUCT.lpCreateParams
        );

        if (self.hwnd == null) {
            return error.CreateWindowFailed;
        }

        _ = w32.SetWindowLongPtrW(self.hwnd.?, w32.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    }

    /// Register the sidebar window class.
    pub fn registerClass(hinstance: w32.HINSTANCE) !void {
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
            .lpfnWndProc = sidebarWndProc,
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

        if (w32.RegisterClassExW(&wc) == 0) {
            return error.RegisterClassFailed;
        }
    }

    /// Resize the sidebar to fit the parent window.
    pub fn resize(self: *Sidebar, parent_height: i32) void {
        if (self.hwnd) |hwnd| {
            const w = if (self.visible)
                Theme.scaled(self.width, self.scale)
            else
                0;
            _ = w32.MoveWindow(hwnd, 0, 0, w, parent_height, 1);
        }
    }

    /// Get the width the sidebar currently occupies (0 if hidden).
    pub fn getWidth(self: *const Sidebar) i32 {
        if (!self.visible) return 0;
        return Theme.scaled(self.width, self.scale);
    }

    /// Toggle sidebar visibility.
    pub fn toggle(self: *Sidebar) void {
        self.visible = !self.visible;
        if (self.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, if (self.visible) w32.SW_SHOW else w32.SW_HIDE);
        }
        // Notify parent to relayout content area
        if (self.parent_hwnd) |parent| {
            _ = w32.PostMessageW(parent, w32.WM_SIZE, 0, 0);
        }
    }

    /// Add a new tab to the sidebar.
    pub fn addTab(self: *Sidebar, name: []const u8) !usize {
        const tab = SidebarTab.init(name);
        try self.tabs.append(tab);
        self.invalidate();
        return self.tabs.items.len - 1;
    }

    /// Remove a tab by index.
    pub fn removeTab(self: *Sidebar, index: usize) void {
        if (index >= self.tabs.items.len) return;
        var tab = self.tabs.orderedRemove(index);
        tab.deinit(self.allocator);
        if (self.active_tab >= self.tabs.items.len and self.tabs.items.len > 0) {
            self.active_tab = self.tabs.items.len - 1;
        }
        self.invalidate();
    }

    /// Rename an existing tab without replacing its metadata.
    pub fn renameTab(self: *Sidebar, index: usize, name: []const u8) void {
        if (index >= self.tabs.items.len) return;
        self.tabs.items[index].setName(name);
        self.invalidate();
    }

    /// Reorder a tab to a new index.
    pub fn reorderTab(self: *Sidebar, from: usize, to: usize) void {
        if (from >= self.tabs.items.len or to >= self.tabs.items.len or from == to) return;

        const tab = self.tabs.orderedRemove(from);
        self.tabs.insert(to, tab) catch return;

        if (self.active_tab == from) {
            self.active_tab = to;
        } else if (from < self.active_tab and to >= self.active_tab) {
            self.active_tab -= 1;
        } else if (from > self.active_tab and to <= self.active_tab) {
            self.active_tab += 1;
        }

        self.invalidate();
    }

    /// Set the active (selected) tab.
    pub fn setActiveTab(self: *Sidebar, index: usize) void {
        if (index < self.tabs.items.len) {
            self.active_tab = index;
            self.invalidate();
        }
    }

    /// Update tab metadata (called periodically from workspace manager).
    pub fn updateTab(self: *Sidebar, index: usize, tab: SidebarTab) void {
        if (index < self.tabs.items.len) {
            self.tabs.items[index].deinit(self.allocator);
            self.tabs.items[index] = tab;
            self.invalidate();
        }
    }

    /// Mark the sidebar as needing repaint.
    fn invalidate(self: *Sidebar) void {
        if (self.hwnd) |hwnd| {
            _ = w32.InvalidateRect(hwnd, null, 0);
        }
    }

    /// Initialize Direct2D resources. Called on first paint.
    fn initD2DResources(self: *Sidebar) void {
        // TODO: Create ID2D1Factory, ID2D1HwndRenderTarget, IDWriteFactory
        // These will be COM objects initialized via D2D1CreateFactory(),
        // CreateHwndRenderTarget(), and DWriteCreateFactory().
        _ = self;
    }

    /// Release Direct2D resources.
    fn destroyD2DResources(self: *Sidebar) void {
        // TODO: Release COM objects
        self.d2d_factory = null;
        self.render_target = null;
        self.dwrite_factory = null;
    }

    /// Paint the sidebar using Direct2D.
    fn paint(self: *Sidebar) void {
        if (self.render_target == null) {
            self.initD2DResources();
        }

        // TODO: Actual Direct2D rendering. For now, fall back to GDI.
        if (self.hwnd) |hwnd| {
            var ps: w32.PAINTSTRUCT = undefined;
            const hdc = w32.BeginPaint(hwnd, &ps);
            if (hdc) |dc| {
                // Fill background
                var rect: w32.RECT = undefined;
                _ = w32.GetClientRect(hwnd, &rect);
                const brush = w32.CreateSolidBrush(self.theme.sidebar_bg.toColorRef());
                if (brush) |b| {
                    _ = w32.FillRect(dc, &rect, b);
                    _ = w32.DeleteObject(b);
                }

                // Draw tabs using GDI as interim before Direct2D
                self.paintTabsGdi(dc, rect);
            }
            _ = w32.EndPaint(hwnd, &ps);
        }
    }

    /// Interim GDI tab painting until Direct2D is fully wired up.
    fn paintTabsGdi(self: *Sidebar, hdc: w32.HDC, client_rect: w32.RECT) void {
        const tab_h = Theme.scaled(Theme.sidebar_tab_height, self.scale);
        const padding = Theme.scaled(Theme.sidebar_tab_padding, self.scale);
        const header_height = Theme.scaled(40, self.scale); // Logo/drag area

        // Sidebar/content separator.
        var separator_rect = w32.RECT{
            .left = client_rect.right - 1,
            .top = client_rect.top,
            .right = client_rect.right,
            .bottom = client_rect.bottom,
        };
        const separator_brush = w32.CreateSolidBrush(self.theme.sidebar_separator.toColorRef());
        if (separator_brush) |b| {
            _ = w32.FillRect(hdc, &separator_rect, b);
            _ = w32.DeleteObject(b);
        }

        for (self.tabs.items, 0..) |tab, i| {
            const y = header_height + @as(i32, @intCast(i)) * tab_h + self.scroll_offset;

            // Tab background
            const bg_color = if (i == self.active_tab)
                self.theme.sidebar_tab_active_bg
            else if (self.hovered_tab != null and self.hovered_tab.? == i)
                self.theme.sidebar_tab_hover_bg
            else
                self.theme.sidebar_tab_bg;

            var tab_rect = w32.RECT{
                .left = padding,
                .top = y,
                .right = Theme.scaled(self.width, self.scale) - padding,
                .bottom = y + tab_h - padding,
            };

            const brush = w32.CreateSolidBrush(bg_color.toColorRef());
            if (brush) |b| {
                _ = w32.FillRect(hdc, &tab_rect, b);
                _ = w32.DeleteObject(b);
            }

            if (i == self.active_tab) {
                var accent_rect = tab_rect;
                accent_rect.right = accent_rect.left + Theme.scaled(4, self.scale);
                const accent_brush = w32.CreateSolidBrush(self.theme.accent.toColorRef());
                if (accent_brush) |b| {
                    _ = w32.FillRect(hdc, &accent_rect, b);
                    _ = w32.DeleteObject(b);
                }
            }

            // Tab name text
            _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
            tab_rect.left += padding;
            tab_rect.top += padding;
            const title = tab.getName();
            self.drawTextLine(
                hdc,
                title,
                &tab_rect,
                self.theme.sidebar_text.toColorRef(),
                w32.DT_LEFT | w32.DT_TOP | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
            );

            // Latest notification snippet / cwd fallback
            const detail = if (tab.last_notification_len > 0)
                tab.last_notification[0..tab.last_notification_len]
            else
                tab.getCwd();
            if (detail.len > 0) {
                var detail_rect = tab_rect;
                detail_rect.top += Theme.scaled(18, self.scale);
                self.drawTextLine(
                    hdc,
                    detail,
                    &detail_rect,
                    self.theme.sidebar_text_dim.toColorRef(),
                    w32.DT_LEFT | w32.DT_TOP | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }

            var metadata_buf: [128]u8 = undefined;
            const metadata = self.formatTabMetadata(tab, &metadata_buf);
            if (metadata.len > 0) {
                var metadata_rect = tab_rect;
                metadata_rect.top += Theme.scaled(34, self.scale);
                self.drawTextLine(
                    hdc,
                    metadata,
                    &metadata_rect,
                    self.theme.accent.toColorRef(),
                    w32.DT_LEFT | w32.DT_TOP | w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS | w32.DT_NOPREFIX,
                );
            }

            // Notification badge
            if (tab.unread_count > 0) {
                const badge_size = Theme.scaled(Theme.notification_badge_size, self.scale);
                const badge_x = Theme.scaled(self.width, self.scale) - padding * 3;
                const badge_y = y + @divTrunc(tab_h, 2) - @divTrunc(badge_size, 2);
                var badge_rect = w32.RECT{
                    .left = badge_x,
                    .top = badge_y,
                    .right = badge_x + badge_size,
                    .bottom = badge_y + badge_size,
                };
                const badge_brush = w32.CreateSolidBrush(self.theme.notification_badge_bg.toColorRef());
                if (badge_brush) |b| {
                    _ = w32.FillRect(hdc, &badge_rect, b);
                    _ = w32.DeleteObject(b);
                }
            }
        }

        // "+ New Workspace" button at the bottom of the tab list
        const btn_y = header_height + @as(i32, @intCast(self.tabs.items.len)) * tab_h + self.scroll_offset + padding;
        var btn_rect = w32.RECT{
            .left = padding,
            .top = btn_y,
            .right = Theme.scaled(self.width, self.scale) - padding,
            .bottom = btn_y + tab_h - padding,
        };
        _ = w32.SetTextColor(hdc, self.theme.accent.toColorRef());
        const new_workspace = std.unicode.utf8ToUtf16LeStringLiteral("+ New Workspace");
        _ = w32.DrawTextW(
            hdc,
            new_workspace,
            @intCast(new_workspace.len),
            &btn_rect,
            w32.DT_LEFT | w32.DT_VCENTER | w32.DT_SINGLELINE | w32.DT_NOPREFIX,
        );
    }

    fn drawTextLine(
        self: *Sidebar,
        hdc: w32.HDC,
        text: []const u8,
        rect: *w32.RECT,
        color: u32,
        format: u32,
    ) void {
        _ = self;
        if (text.len == 0) return;
        _ = w32.SetTextColor(hdc, color);
        var text_buf: [256]u16 = undefined;
        const text_len = std.unicode.utf8ToUtf16Le(&text_buf, text) catch 0;
        if (text_len == 0) return;
        _ = w32.DrawTextW(
            hdc,
            @ptrCast(&text_buf),
            @intCast(text_len),
            rect,
            format,
        );
    }

    fn formatTabMetadata(self: *Sidebar, tab: SidebarTab, buf: []u8) []const u8 {
        _ = self;
        var stream = std.io.fixedBufferStream(buf);
        const writer = stream.writer();
        var has_value = false;

        const shell_label = tab.shell_type.displayName();
        if (shell_label.len > 0 and tab.shell_type != .custom) {
            writer.writeAll(shell_label) catch return stream.getWritten();
            has_value = true;
        }

        const branch = tab.getGitBranch();
        if (branch.len > 0) {
            if (has_value) writer.writeAll(" | ") catch return stream.getWritten();
            writer.writeAll(branch) catch return stream.getWritten();
            has_value = true;
        }

        if (tab.pr_number > 0) {
            if (has_value) writer.writeAll(" | ") catch return stream.getWritten();
            writer.print("PR #{d}", .{tab.pr_number}) catch return stream.getWritten();
            has_value = true;
        }

        if (tab.port_count > 0) {
            if (has_value) writer.writeAll(" | ") catch return stream.getWritten();
            writer.writeAll(":") catch return stream.getWritten();
            for (tab.ports[0..tab.port_count], 0..) |port, idx| {
                if (idx > 0) writer.writeAll(",") catch return stream.getWritten();
                writer.print("{d}", .{port}) catch return stream.getWritten();
            }
        }

        return stream.getWritten();
    }

    /// Hit-test to determine which tab (if any) was clicked.
    fn hitTestTab(self: *Sidebar, y: i32) ?usize {
        const tab_h = Theme.scaled(Theme.sidebar_tab_height, self.scale);
        const header_height = Theme.scaled(40, self.scale);

        const adjusted_y = y - header_height - self.scroll_offset;
        if (adjusted_y < 0) return null;

        const index = @as(usize, @intCast(@divTrunc(adjusted_y, tab_h)));
        if (index < self.tabs.items.len) return index;
        return null;
    }

    fn hitTestNewWorkspace(self: *Sidebar, y: i32) bool {
        const tab_h = Theme.scaled(Theme.sidebar_tab_height, self.scale);
        const header_height = Theme.scaled(40, self.scale);
        const padding = Theme.scaled(Theme.sidebar_tab_padding, self.scale);
        const btn_y = header_height + @as(i32, @intCast(self.tabs.items.len)) * tab_h + self.scroll_offset + padding;
        return y >= btn_y and y < btn_y + tab_h - padding;
    }

    fn dragTargetForY(self: *Sidebar, y: i32) ?usize {
        if (self.tabs.items.len == 0) return null;
        const tab_h = Theme.scaled(Theme.sidebar_tab_height, self.scale);
        const header_height = Theme.scaled(40, self.scale);
        const adjusted_y = y - header_height - self.scroll_offset;
        if (adjusted_y <= 0) return 0;
        const raw_index = @divTrunc(adjusted_y, tab_h);
        const clamped = std.math.clamp(raw_index, 0, @as(i32, @intCast(self.tabs.items.len - 1)));
        return @intCast(clamped);
    }

    fn ensureMouseLeaveTracking(self: *Sidebar) void {
        if (self.tracking_mouse) return;
        const hwnd = self.hwnd orelse return;
        var tme = w32.TRACKMOUSEEVENT{
            .cbSize = @sizeOf(w32.TRACKMOUSEEVENT),
            .dwFlags = w32.TME_LEAVE,
            .hwndTrack = hwnd,
            .dwHoverTime = 0,
        };
        _ = w32.TrackMouseEvent(&tme);
        self.tracking_mouse = true;
    }

    fn clearDrag(self: *Sidebar) void {
        self.dragging_tab = null;
        self.drag_start_y = 0;
        self.drag_current_y = 0;
        _ = w32.ReleaseCapture();
    }

    fn getPoint(lparam: isize) struct { x: i32, y: i32 } {
        return .{
            .x = @as(i16, @truncate(lparam & 0xFFFF)),
            .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
        };
    }

    /// Window procedure for the sidebar HWND.
    fn sidebarWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.C) isize {
        const self = getSidebarPtr(hwnd);
        if (self == null) {
            return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
        }
        const sidebar = self.?;

        switch (msg) {
            w32.WM_PAINT => {
                sidebar.paint();
                return 0;
            },
            w32.WM_LBUTTONDOWN => {
                const pt = getPoint(lparam);
                const y = pt.y;
                if (sidebar.hitTestTab(y)) |tab_index| {
                    sidebar.dragging_tab = tab_index;
                    sidebar.drag_start_y = y;
                    sidebar.drag_current_y = y;
                    if (sidebar.hwnd) |child| _ = w32.SetCapture(child);
                    sidebar.setActiveTab(tab_index);
                    // Notify parent
                    if (sidebar.parent_hwnd) |parent| {
                        _ = w32.PostMessageW(parent, Sidebar.WM_CMUX_TAB_CLICKED, tab_index, 0);
                    }
                } else if (sidebar.hitTestNewWorkspace(y)) {
                    if (sidebar.parent_hwnd) |parent| {
                        _ = w32.PostMessageW(parent, Sidebar.WM_CMUX_NEW_WORKSPACE, 0, 0);
                    }
                }
                return 0;
            },
            w32.WM_LBUTTONUP => {
                sidebar.clearDrag();
                return 0;
            },
            w32.WM_LBUTTONDBLCLK => {
                const pt = getPoint(lparam);
                if (sidebar.hitTestTab(pt.y)) |tab_index| {
                    if (sidebar.parent_hwnd) |parent| {
                        _ = w32.PostMessageW(parent, Sidebar.WM_CMUX_TAB_RENAME, tab_index, 0);
                    }
                }
                return 0;
            },
            w32.WM_RBUTTONUP => {
                const pt = getPoint(lparam);
                if (sidebar.hitTestTab(pt.y)) |tab_index| {
                    if (sidebar.parent_hwnd) |parent| {
                        const context_payload: usize = (@as(usize, @intCast(@as(u16, @bitCast(pt.x)))) << 16) |
                            @as(usize, @intCast(tab_index));
                        _ = w32.PostMessageW(parent, Sidebar.WM_CMUX_TAB_CONTEXT, context_payload, @as(isize, pt.y));
                    }
                    return 0;
                }
                return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
            },
            w32.WM_MOUSEMOVE => {
                sidebar.ensureMouseLeaveTracking();
                const pt = getPoint(lparam);
                const y = pt.y;
                const new_hover = sidebar.hitTestTab(y);
                if (new_hover != sidebar.hovered_tab) {
                    sidebar.hovered_tab = new_hover;
                    sidebar.invalidate();
                }
                if (sidebar.dragging_tab) |from| {
                    sidebar.drag_current_y = y;
                    const delta = if (y >= sidebar.drag_start_y) y - sidebar.drag_start_y else sidebar.drag_start_y - y;
                    if (delta >= Theme.scaled(6, sidebar.scale)) {
                        if (sidebar.dragTargetForY(y)) |to| {
                            if (to != from) {
                                sidebar.dragging_tab = to;
                                if (sidebar.parent_hwnd) |parent| {
                                    const payload = (@as(usize, from) << 16) | @as(usize, to);
                                    _ = w32.SendMessageW(parent, Sidebar.WM_CMUX_TAB_REORDER, payload, 0);
                                }
                            }
                        }
                    }
                }
                return 0;
            },
            w32.WM_MOUSELEAVE => {
                sidebar.tracking_mouse = false;
                sidebar.hovered_tab = null;
                sidebar.invalidate();
                return 0;
            },
            w32.WM_MOUSEWHEEL => {
                const delta: i16 = @truncate(@as(u32, @bitCast(@as(i32, @truncate(wparam >> 16)))));
                sidebar.scroll_offset += if (delta > 0) 30 else -30;
                sidebar.invalidate();
                return 0;
            },
            w32.WM_ERASEBKGND => {
                return 1; // Prevent flicker — we paint the full background
            },
            else => {},
        }

        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
    }

    /// Extract Sidebar pointer from GWLP_USERDATA.
    fn getSidebarPtr(hwnd: w32.HWND) ?*Sidebar {
        const ptr = w32.GetWindowLongPtrW(hwnd, w32.GWLP_USERDATA);
        if (ptr == 0) return null;
        return @ptrFromInt(@as(usize, @bitCast(ptr)));
    }

    /// Convert ASCII string to wide string at comptime.
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
