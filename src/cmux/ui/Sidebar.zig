const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;
const Color = @import("Theme.zig").Color;
const SidebarTab = @import("SidebarTab.zig");
const WorkspaceManager = @import("../workspace/WorkspaceManager.zig");

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

        _ = client_rect;

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

            // Tab name text
            _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
            _ = w32.SetTextColor(hdc, self.theme.sidebar_text.toColorRef());
            tab_rect.left += padding;
            tab_rect.top += padding;
            _ = tab;
            // TODO: DrawTextW with tab.name once we handle UTF-16 conversion

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
        _ = btn_rect;
        // TODO: DrawTextW "+ New Workspace"
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
                const y: i32 = @as(i16, @truncate(@as(u32, @bitCast(@as(i32, @truncate(lparam >> 16))))));
                if (sidebar.hitTestTab(y)) |tab_index| {
                    sidebar.setActiveTab(tab_index);
                    // Notify parent
                    if (sidebar.parent_hwnd) |parent| {
                        _ = w32.PostMessageW(parent, Sidebar.WM_CMUX_TAB_CLICKED, tab_index, 0);
                    }
                }
                return 0;
            },
            w32.WM_MOUSEMOVE => {
                const y: i32 = @as(i16, @truncate(@as(u32, @bitCast(@as(i32, @truncate(lparam >> 16))))));
                const new_hover = sidebar.hitTestTab(y);
                if (new_hover != sidebar.hovered_tab) {
                    sidebar.hovered_tab = new_hover;
                    sidebar.invalidate();
                }
                return 0;
            },
            w32.WM_MOUSELEAVE => {
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
