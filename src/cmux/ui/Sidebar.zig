const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");
const dw = @import("../../font/directwrite.zig");
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
    hovered_new_workspace: bool = false,

    // Direct2D resources (opaque pointers, initialized on WM_CREATE)
    d2d_attempted: bool = false,
    d2d_factory: ?*anyopaque = null,
    render_target: ?*anyopaque = null,
    dwrite_factory: ?*anyopaque = null,
    title_text_format: ?*anyopaque = null,
    detail_text_format: ?*anyopaque = null,
    metadata_text_format: ?*anyopaque = null,
    button_text_format: ?*anyopaque = null,
    badge_text_format: ?*anyopaque = null,

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
            if (self.renderTarget()) |render_target| {
                _ = render_target.vtable.Resize(render_target, .{
                    .width = @intCast(@max(w, 1)),
                    .height = @intCast(@max(parent_height, 1)),
                });
            }
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
        if (self.d2d_attempted) return;
        self.d2d_attempted = true;

        const hwnd = self.hwnd orelse return;

        var factory_ptr: ?*anyopaque = null;
        if (D2D1CreateFactory(.single_threaded, &IID_ID2D1Factory, null, &factory_ptr) != dw.S_OK or factory_ptr == null) {
            return;
        }
        self.d2d_factory = factory_ptr;

        var dwrite_ptr: ?*anyopaque = null;
        if (dw.DWriteCreateFactory(.shared, &dw.IID_IDWriteFactory, &dwrite_ptr) != dw.S_OK or dwrite_ptr == null) {
            self.destroyD2DResources();
            return;
        }
        self.dwrite_factory = dwrite_ptr;

        var client_rect: w32.RECT = undefined;
        _ = w32.GetClientRect(hwnd, &client_rect);

        const factory = self.d2dFactory() orelse {
            self.destroyD2DResources();
            return;
        };
        const dwrite_factory = self.dwriteFactory() orelse {
            self.destroyD2DResources();
            return;
        };

        var render_target: ?*ID2D1HwndRenderTarget = null;
        const render_props = D2D1_RENDER_TARGET_PROPERTIES{
            .type = .default,
            .pixelFormat = .{
                .format = 0,
                .alphaMode = .unknown,
            },
            .dpiX = 0,
            .dpiY = 0,
            .usage = 0,
            .minLevel = 0,
        };
        const hwnd_props = D2D1_HWND_RENDER_TARGET_PROPERTIES{
            .hwnd = hwnd,
            .pixelSize = .{
                .width = @intCast(@max(client_rect.right - client_rect.left, 1)),
                .height = @intCast(@max(client_rect.bottom - client_rect.top, 1)),
            },
            .presentOptions = .none,
        };
        if (factory.vtable.CreateHwndRenderTarget(factory, &render_props, &hwnd_props, &render_target) != dw.S_OK or render_target == null) {
            self.destroyD2DResources();
            return;
        }
        self.render_target = render_target;

        self.title_text_format = dwrite_factory.createTextFormat(Theme.font_size_tab * self.scale) catch null;
        self.detail_text_format = dwrite_factory.createTextFormat(11.0 * self.scale) catch null;
        self.metadata_text_format = dwrite_factory.createTextFormat(10.0 * self.scale) catch null;
        self.button_text_format = dwrite_factory.createTextFormat(12.0 * self.scale) catch null;
        self.badge_text_format = dwrite_factory.createTextFormat(Theme.font_size_badge * self.scale) catch null;

        if (self.title_text_format == null or
            self.detail_text_format == null or
            self.metadata_text_format == null or
            self.button_text_format == null or
            self.badge_text_format == null)
        {
            self.destroyD2DResources();
        }
    }

    /// Release Direct2D resources.
    fn destroyD2DResources(self: *Sidebar) void {
        releaseComObject(self.badge_text_format);
        releaseComObject(self.button_text_format);
        releaseComObject(self.metadata_text_format);
        releaseComObject(self.detail_text_format);
        releaseComObject(self.title_text_format);
        releaseComObject(self.render_target);
        releaseComObject(self.dwrite_factory);
        releaseComObject(self.d2d_factory);
        self.badge_text_format = null;
        self.button_text_format = null;
        self.metadata_text_format = null;
        self.detail_text_format = null;
        self.title_text_format = null;
        self.d2d_factory = null;
        self.render_target = null;
        self.dwrite_factory = null;
        self.d2d_attempted = false;
    }

    /// Paint the sidebar using Direct2D.
    fn paint(self: *Sidebar) void {
        if (self.render_target == null) {
            self.initD2DResources();
        }

        if (self.hwnd) |hwnd| {
            var ps: w32.PAINTSTRUCT = undefined;
            _ = w32.BeginPaint(hwnd, &ps) orelse return;
            defer _ = w32.EndPaint(hwnd, &ps);

            var rect: w32.RECT = undefined;
            _ = w32.GetClientRect(hwnd, &rect);

            if (self.renderTarget()) |render_target| {
                self.paintTabsD2D(render_target, rect);
                return;
            }

            const dc = ps.hdc;
            const brush = w32.CreateSolidBrush(self.theme.sidebar_bg.toColorRef());
            if (brush) |b| {
                _ = w32.FillRect(dc, &rect, b);
                _ = w32.DeleteObject(b);
            }
            self.paintTabsGdi(dc, rect);
        }
    }

    fn paintTabsD2D(self: *Sidebar, render_target: *ID2D1HwndRenderTarget, client_rect: w32.RECT) void {
        render_target.vtable.BeginDraw(render_target);
        render_target.vtable.Clear(render_target, &toD2DColor(self.theme.sidebar_bg));

        const tab_h = Theme.scaled(Theme.sidebar_tab_height, self.scale);
        const padding = Theme.scaled(Theme.sidebar_tab_padding, self.scale);
        const header_height = Theme.scaled(40, self.scale);
        const text_column_left = padding + Theme.scaled(10, self.scale);
        const unread_column_width = Theme.scaled(28, self.scale);

        if (self.createBrush(render_target, self.theme.sidebar_separator)) |separator_brush| {
            defer releaseComObject(separator_brush);
            const separator_rect = w32.RECT{
                .left = client_rect.right - 1,
                .top = client_rect.top,
                .right = client_rect.right,
                .bottom = client_rect.bottom,
            };
            const separator_rect_f = toRectF(separator_rect);
            render_target.vtable.FillRectangle(render_target, &separator_rect_f, separator_brush);
        }

        for (self.tabs.items, 0..) |tab, i| {
            const y = header_height + @as(i32, @intCast(i)) * tab_h + self.scroll_offset;
            if (y + tab_h <= client_rect.top or y >= client_rect.bottom) continue;

            var tab_rect = w32.RECT{
                .left = padding,
                .top = y,
                .right = Theme.scaled(self.width, self.scale) - padding,
                .bottom = y + tab_h - padding,
            };

            const bg_color = if (i == self.active_tab)
                self.theme.sidebar_tab_active_bg
            else if (self.hovered_tab != null and self.hovered_tab.? == i)
                self.theme.sidebar_tab_hover_bg
            else
                self.theme.sidebar_tab_bg;

            if (self.createBrush(render_target, bg_color)) |bg_brush| {
                defer releaseComObject(bg_brush);
                const tab_rect_f = toRectF(tab_rect);
                render_target.vtable.FillRectangle(render_target, &tab_rect_f, bg_brush);
            }

            if (i == self.active_tab) {
                if (self.createBrush(render_target, self.theme.sidebar_separator)) |outline_brush| {
                    defer releaseComObject(outline_brush);
                    const tab_rect_f = toRectF(tab_rect);
                    render_target.vtable.DrawRectangle(render_target, &tab_rect_f, outline_brush, 1.0, null);
                }

                if (self.createBrush(render_target, self.theme.accent)) |accent_brush| {
                    defer releaseComObject(accent_brush);
                    var accent_rect = tab_rect;
                    accent_rect.right = accent_rect.left + Theme.scaled(4, self.scale);
                    const accent_rect_f = toRectF(accent_rect);
                    render_target.vtable.FillRectangle(render_target, &accent_rect_f, accent_brush);
                }
            }

            tab_rect.left = text_column_left;
            tab_rect.top += padding;
            tab_rect.right -= unread_column_width;

            if (self.createBrush(render_target, self.theme.sidebar_text)) |title_brush| {
                defer releaseComObject(title_brush);
                self.drawTextLineD2D(render_target, tab.getName(), self.title_text_format.?, tab_rect, title_brush);
            }

            const detail = if (tab.last_notification_len > 0)
                tab.last_notification[0..tab.last_notification_len]
            else
                tab.getCwd();
            if (detail.len > 0) {
                if (self.createBrush(render_target, self.theme.sidebar_text_dim)) |detail_brush| {
                    defer releaseComObject(detail_brush);
                    var detail_rect = tab_rect;
                    detail_rect.top += Theme.scaled(18, self.scale);
                    self.drawTextLineD2D(render_target, detail, self.detail_text_format.?, detail_rect, detail_brush);
                }
            }

            var metadata_buf: [128]u8 = undefined;
            const metadata = self.formatTabMetadata(tab, &metadata_buf);
            if (metadata.len > 0) {
                if (self.createBrush(render_target, self.theme.accent)) |metadata_brush| {
                    defer releaseComObject(metadata_brush);
                    var metadata_rect = tab_rect;
                    metadata_rect.top += Theme.scaled(34, self.scale);
                    self.drawTextLineD2D(render_target, metadata, self.metadata_text_format.?, metadata_rect, metadata_brush);
                }
            }

            if (tab.unread_count > 0) {
                const badge_size = Theme.scaled(Theme.notification_badge_size, self.scale);
                const badge_x = Theme.scaled(self.width, self.scale) - unread_column_width;
                const badge_y = y + @divTrunc(tab_h, 2) - @divTrunc(badge_size, 2);
                const badge_rect = w32.RECT{
                    .left = badge_x,
                    .top = badge_y,
                    .right = badge_x + badge_size,
                    .bottom = badge_y + badge_size,
                };
                if (self.createBrush(render_target, self.theme.notification_badge_bg)) |badge_brush| {
                    defer releaseComObject(badge_brush);
                    const badge_rect_f = toRectF(badge_rect);
                    render_target.vtable.FillRectangle(render_target, &badge_rect_f, badge_brush);
                }

                if (self.createBrush(render_target, self.theme.notification_badge_text)) |badge_text_brush| {
                    defer releaseComObject(badge_text_brush);
                    var badge_buf: [8]u8 = undefined;
                    const badge_text = std.fmt.bufPrint(&badge_buf, "{d}", .{@min(tab.unread_count, 99)}) catch "";
                    self.drawTextLineD2D(render_target, badge_text, self.badge_text_format.?, badge_rect, badge_text_brush);
                }
            }
        }

        const btn_y = header_height + @as(i32, @intCast(self.tabs.items.len)) * tab_h + self.scroll_offset + padding;
        var btn_rect = w32.RECT{
            .left = padding,
            .top = btn_y,
            .right = Theme.scaled(self.width, self.scale) - padding,
            .bottom = btn_y + tab_h - padding,
        };

        const btn_bg = if (self.hovered_new_workspace)
            self.theme.sidebar_tab_hover_bg
        else
            self.theme.sidebar_tab_bg;
        if (self.createBrush(render_target, btn_bg)) |btn_bg_brush| {
            defer releaseComObject(btn_bg_brush);
            const btn_rect_f = toRectF(btn_rect);
            render_target.vtable.FillRectangle(render_target, &btn_rect_f, btn_bg_brush);
        }
        if (self.createBrush(render_target, self.theme.sidebar_separator)) |btn_outline_brush| {
            defer releaseComObject(btn_outline_brush);
            const btn_rect_f = toRectF(btn_rect);
            render_target.vtable.DrawRectangle(render_target, &btn_rect_f, btn_outline_brush, 1.0, null);
        }
        if (self.createBrush(render_target, self.theme.accent)) |btn_text_brush| {
            defer releaseComObject(btn_text_brush);
            btn_rect.left = text_column_left;
            self.drawTextLineD2D(render_target, "+ New Workspace", self.button_text_format.?, btn_rect, btn_text_brush);
        }

        if (render_target.vtable.EndDraw(render_target, null, null) != dw.S_OK) {
            self.destroyD2DResources();
        }
    }

    /// Interim GDI tab painting until Direct2D is fully wired up.
    fn paintTabsGdi(self: *Sidebar, hdc: w32.HDC, client_rect: w32.RECT) void {
        const tab_h = Theme.scaled(Theme.sidebar_tab_height, self.scale);
        const padding = Theme.scaled(Theme.sidebar_tab_padding, self.scale);
        const header_height = Theme.scaled(40, self.scale); // Logo/drag area
        const text_column_left = padding + Theme.scaled(10, self.scale);
        const unread_column_width = Theme.scaled(28, self.scale);

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
            if (y + tab_h <= client_rect.top or y >= client_rect.bottom) continue;

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
                const outline_pen = w32.CreatePen(0, 1, self.theme.sidebar_separator.toColorRef());
                if (outline_pen) |pen| {
                    const old_pen = w32.SelectObject(hdc, pen);
                    _ = w32.MoveToEx(hdc, tab_rect.left, tab_rect.top, null);
                    _ = w32.LineTo(hdc, tab_rect.right - 1, tab_rect.top);
                    _ = w32.LineTo(hdc, tab_rect.right - 1, tab_rect.bottom - 1);
                    _ = w32.LineTo(hdc, tab_rect.left, tab_rect.bottom - 1);
                    _ = w32.LineTo(hdc, tab_rect.left, tab_rect.top);
                    _ = w32.SelectObject(hdc, old_pen);
                    _ = w32.DeleteObject(pen);
                }
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
            tab_rect.left = text_column_left;
            tab_rect.top += padding;
            tab_rect.right -= unread_column_width;
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
                const badge_x = Theme.scaled(self.width, self.scale) - unread_column_width;
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
        const new_workspace_bg = if (self.hovered_new_workspace)
            self.theme.sidebar_tab_hover_bg
        else
            self.theme.sidebar_tab_bg;
        const new_workspace_brush = w32.CreateSolidBrush(new_workspace_bg.toColorRef());
        if (new_workspace_brush) |b| {
            _ = w32.FillRect(hdc, &btn_rect, b);
            _ = w32.DeleteObject(b);
        }

        const new_workspace_pen = w32.CreatePen(0, 1, self.theme.sidebar_separator.toColorRef());
        if (new_workspace_pen) |pen| {
            const old_pen = w32.SelectObject(hdc, pen);
            _ = w32.MoveToEx(hdc, btn_rect.left, btn_rect.top, null);
            _ = w32.LineTo(hdc, btn_rect.right - 1, btn_rect.top);
            _ = w32.LineTo(hdc, btn_rect.right - 1, btn_rect.bottom - 1);
            _ = w32.LineTo(hdc, btn_rect.left, btn_rect.bottom - 1);
            _ = w32.LineTo(hdc, btn_rect.left, btn_rect.top);
            _ = w32.SelectObject(hdc, old_pen);
            _ = w32.DeleteObject(pen);
        }

        btn_rect.left = text_column_left;
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
                const new_hover_new_workspace = sidebar.hitTestNewWorkspace(y);
                if (new_hover != sidebar.hovered_tab) {
                    sidebar.hovered_tab = new_hover;
                    sidebar.invalidate();
                }
                if (new_hover_new_workspace != sidebar.hovered_new_workspace) {
                    sidebar.hovered_new_workspace = new_hover_new_workspace;
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
                sidebar.hovered_new_workspace = false;
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

const D2D1_FACTORY_TYPE = enum(u32) {
    single_threaded = 0,
    multi_threaded = 1,
};

const D2D1_PRESENT_OPTIONS = enum(u32) {
    none = 0,
    retain_contents = 1,
    immediately = 2,
};

const D2D1_RENDER_TARGET_TYPE = enum(u32) {
    default = 0,
    software = 1,
    hardware = 2,
};

const D2D1_ALPHA_MODE = enum(u32) {
    unknown = 0,
    premultiplied = 1,
    straight = 2,
    ignore = 3,
};

const D2D1_COLOR_F = extern struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32,
};

const D2D1_POINT_2F = extern struct {
    x: f32,
    y: f32,
};

const D2D1_RECT_F = extern struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

const D2D1_SIZE_U = extern struct {
    width: u32,
    height: u32,
};

const D2D1_PIXEL_FORMAT = extern struct {
    format: u32,
    alphaMode: D2D1_ALPHA_MODE,
};

const D2D1_RENDER_TARGET_PROPERTIES = extern struct {
    type: D2D1_RENDER_TARGET_TYPE,
    pixelFormat: D2D1_PIXEL_FORMAT,
    dpiX: f32,
    dpiY: f32,
    usage: u32,
    minLevel: u32,
};

const D2D1_HWND_RENDER_TARGET_PROPERTIES = extern struct {
    hwnd: w32.HWND,
    pixelSize: D2D1_SIZE_U,
    presentOptions: D2D1_PRESENT_OPTIONS,
};

const ID2D1Factory = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*const ID2D1Factory, *const dw.GUID, *?*anyopaque) callconv(.c) dw.HRESULT,
        AddRef: *const fn (*const ID2D1Factory) callconv(.c) u32,
        Release: *const fn (*const ID2D1Factory) callconv(.c) u32,
        ReloadSystemMetrics: *const fn (*const ID2D1Factory) callconv(.c) dw.HRESULT,
        GetDesktopDpi: *const fn (*const ID2D1Factory, *f32, *f32) callconv(.c) void,
        CreateRectangleGeometry: *const fn () callconv(.c) dw.HRESULT,
        CreateRoundedRectangleGeometry: *const fn () callconv(.c) dw.HRESULT,
        CreateEllipseGeometry: *const fn () callconv(.c) dw.HRESULT,
        CreateGeometryGroup: *const fn () callconv(.c) dw.HRESULT,
        CreateTransformedGeometry: *const fn () callconv(.c) dw.HRESULT,
        CreatePathGeometry: *const fn () callconv(.c) dw.HRESULT,
        CreateStrokeStyle: *const fn () callconv(.c) dw.HRESULT,
        CreateDrawingStateBlock: *const fn () callconv(.c) dw.HRESULT,
        CreateWicBitmapRenderTarget: *const fn () callconv(.c) dw.HRESULT,
        CreateHwndRenderTarget: *const fn (
            *const ID2D1Factory,
            *const D2D1_RENDER_TARGET_PROPERTIES,
            *const D2D1_HWND_RENDER_TARGET_PROPERTIES,
            *?*ID2D1HwndRenderTarget,
        ) callconv(.c) dw.HRESULT,
    };
};

const ID2D1RenderTarget = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*const ID2D1RenderTarget, *const dw.GUID, *?*anyopaque) callconv(.c) dw.HRESULT,
        AddRef: *const fn (*const ID2D1RenderTarget) callconv(.c) u32,
        Release: *const fn (*const ID2D1RenderTarget) callconv(.c) u32,
        CreateBitmap: *const fn () callconv(.c) dw.HRESULT,
        CreateBitmapFromWicBitmap: *const fn () callconv(.c) dw.HRESULT,
        CreateSharedBitmap: *const fn () callconv(.c) dw.HRESULT,
        CreateBitmapBrush: *const fn () callconv(.c) dw.HRESULT,
        CreateSolidColorBrush: *const fn (
            *const ID2D1RenderTarget,
            *const D2D1_COLOR_F,
            ?*const anyopaque,
            *?*ID2D1SolidColorBrush,
        ) callconv(.c) dw.HRESULT,
        DrawLine: *const fn () callconv(.c) void,
        DrawRectangle: *const fn (*const ID2D1RenderTarget, *const D2D1_RECT_F, *ID2D1SolidColorBrush, f32, ?*anyopaque) callconv(.c) void,
        FillRectangle: *const fn (*const ID2D1RenderTarget, *const D2D1_RECT_F, *ID2D1SolidColorBrush) callconv(.c) void,
        DrawRoundedRectangle: *const fn () callconv(.c) void,
        FillRoundedRectangle: *const fn () callconv(.c) void,
        DrawEllipse: *const fn () callconv(.c) void,
        FillEllipse: *const fn () callconv(.c) void,
        DrawGeometry: *const fn () callconv(.c) void,
        FillGeometry: *const fn () callconv(.c) void,
        FillMesh: *const fn () callconv(.c) void,
        FillOpacityMask: *const fn () callconv(.c) void,
        DrawBitmap: *const fn () callconv(.c) void,
        DrawText: *const fn (
            *const ID2D1RenderTarget,
            [*]const u16,
            u32,
            *dw.IDWriteTextFormat,
            *const D2D1_RECT_F,
            *ID2D1SolidColorBrush,
            u32,
            u32,
        ) callconv(.c) void,
        DrawTextLayout: *const fn () callconv(.c) void,
        DrawGlyphRun: *const fn () callconv(.c) void,
        SetTransform: *const fn () callconv(.c) void,
        GetTransform: *const fn () callconv(.c) void,
        SetAntialiasMode: *const fn () callconv(.c) void,
        GetAntialiasMode: *const fn () callconv(.c) u32,
        SetTextAntialiasMode: *const fn () callconv(.c) void,
        GetTextAntialiasMode: *const fn () callconv(.c) u32,
        SetTextRenderingParams: *const fn () callconv(.c) void,
        GetTextRenderingParams: *const fn () callconv(.c) ?*anyopaque,
        SetTags: *const fn () callconv(.c) void,
        GetTags: *const fn () callconv(.c) void,
        PushLayer: *const fn () callconv(.c) void,
        PopLayer: *const fn () callconv(.c) void,
        Flush: *const fn () callconv(.c) dw.HRESULT,
        SaveDrawingState: *const fn () callconv(.c) void,
        RestoreDrawingState: *const fn () callconv(.c) void,
        PushAxisAlignedClip: *const fn (*const ID2D1RenderTarget, *const D2D1_RECT_F, u32) callconv(.c) void,
        PopAxisAlignedClip: *const fn (*const ID2D1RenderTarget) callconv(.c) void,
        Clear: *const fn (*const ID2D1RenderTarget, ?*const D2D1_COLOR_F) callconv(.c) void,
        BeginDraw: *const fn (*const ID2D1RenderTarget) callconv(.c) void,
        EndDraw: *const fn (*const ID2D1RenderTarget, ?*u64, ?*u64) callconv(.c) dw.HRESULT,
    };
};

const ID2D1HwndRenderTarget = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        base: ID2D1RenderTarget.VTable,
        CheckWindowState: *const fn () callconv(.c) u32,
        Resize: *const fn (*const ID2D1HwndRenderTarget, D2D1_SIZE_U) callconv(.c) dw.HRESULT,
        GetHwnd: *const fn (*const ID2D1HwndRenderTarget) callconv(.c) w32.HWND,
    };
};

const ID2D1SolidColorBrush = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const fn (*const ID2D1SolidColorBrush, *const dw.GUID, *?*anyopaque) callconv(.c) dw.HRESULT,
        AddRef: *const fn (*const ID2D1SolidColorBrush) callconv(.c) u32,
        Release: *const fn (*const ID2D1SolidColorBrush) callconv(.c) u32,
    };
};

const DWRITE_TEXT_ALIGNMENT_LEADING: u32 = 0;
const DWRITE_PARAGRAPH_ALIGNMENT_NEAR: u32 = 0;
const DWRITE_WORD_WRAPPING_NO_WRAP: u32 = 2;
const D2D1_DRAW_TEXT_OPTIONS_NONE: u32 = 0;
const DWRITE_MEASURING_MODE_NATURAL: u32 = 0;
const D2D1_ANTIALIAS_MODE_PER_PRIMITIVE: u32 = 0;

const IID_ID2D1Factory = dw.GUID{
    .Data1 = 0x06152247,
    .Data2 = 0x6f50,
    .Data3 = 0x465a,
    .Data4 = .{ 0x92, 0x45, 0x11, 0x8b, 0xfd, 0x3b, 0x60, 0x07 },
};

extern "d2d1" fn D2D1CreateFactory(
    factoryType: D2D1_FACTORY_TYPE,
    riid: *const dw.GUID,
    options: ?*const anyopaque,
    factory: *?*anyopaque,
) callconv(.c) dw.HRESULT;

fn releaseComObject(ptr_opt: ?*anyopaque) void {
    if (ptr_opt) |ptr| {
        const unknown: *dw.IUnknown = @ptrCast(@alignCast(ptr));
        _ = unknown.vtable.Release(unknown);
    }
}

fn toD2DColor(color: @import("Theme.zig").Color) D2D1_COLOR_F {
    return .{ .r = color.r, .g = color.g, .b = color.b, .a = color.a };
}

fn toRectF(rect: w32.RECT) D2D1_RECT_F {
    return .{
        .left = @floatFromInt(rect.left),
        .top = @floatFromInt(rect.top),
        .right = @floatFromInt(rect.right),
        .bottom = @floatFromInt(rect.bottom),
    };
}

fn d2dFactory(self: *Sidebar) ?*ID2D1Factory {
    return if (self.d2d_factory) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

fn renderTarget(self: *Sidebar) ?*ID2D1HwndRenderTarget {
    return if (self.render_target) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

fn dwriteFactory(self: *Sidebar) ?*dw.IDWriteFactory {
    return if (self.dwrite_factory) |ptr| @ptrCast(@alignCast(ptr)) else null;
}

fn createBrush(
    self: *Sidebar,
    render_target: *ID2D1HwndRenderTarget,
    color: @import("Theme.zig").Color,
) ?*ID2D1SolidColorBrush {
    _ = self;
    var brush: ?*ID2D1SolidColorBrush = null;
    if (render_target.vtable.base.CreateSolidColorBrush(@ptrCast(render_target), &toD2DColor(color), null, &brush) != dw.S_OK) return null;
    return brush;
}

fn drawTextLineD2D(
    self: *Sidebar,
    render_target: *ID2D1HwndRenderTarget,
    text: []const u8,
    text_format_ptr: *anyopaque,
    rect: w32.RECT,
    brush: *ID2D1SolidColorBrush,
) void {
    _ = self;
    if (text.len == 0) return;
    const text_format: *dw.IDWriteTextFormat = @ptrCast(@alignCast(text_format_ptr));
    text_format.vtable.SetTextAlignment(text_format, DWRITE_TEXT_ALIGNMENT_LEADING);
    text_format.vtable.SetParagraphAlignment(text_format, DWRITE_PARAGRAPH_ALIGNMENT_NEAR);
    text_format.vtable.SetWordWrapping(text_format, DWRITE_WORD_WRAPPING_NO_WRAP);

    var text_buf: [256]u16 = undefined;
    const text_len = std.unicode.utf8ToUtf16Le(&text_buf, text) catch 0;
    if (text_len == 0) return;

    const rect_f = toRectF(rect);
    render_target.vtable.base.DrawText(
        @ptrCast(render_target),
        @ptrCast(&text_buf),
        @intCast(text_len),
        text_format,
        &rect_f,
        brush,
        D2D1_DRAW_TEXT_OPTIONS_NONE,
        DWRITE_MEASURING_MODE_NATURAL,
    );
}

fn createTextFormat(factory: *dw.IDWriteFactory, size: f32) !*anyopaque {
    var format_ptr: ?*anyopaque = null;
    if (factory.vtable.CreateTextFormat(
        factory,
        std.unicode.utf8ToUtf16LeStringLiteral(Theme.font_family),
        null,
        .normal,
        .normal,
        .normal,
        size,
        std.unicode.utf8ToUtf16LeStringLiteral("en-us"),
        &format_ptr,
    ) != dw.S_OK or format_ptr == null) return error.DirectWriteError;
    return format_ptr.?;
}
