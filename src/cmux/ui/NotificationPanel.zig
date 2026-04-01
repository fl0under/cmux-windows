const std = @import("std");
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;
const Color = @import("Theme.zig").Color;
const NotificationStore = @import("../notifications/NotificationStore.zig").NotificationStore;

/// A dropdown panel that displays the notification list.
/// Appears when the user presses Ctrl+I or clicks the notification icon.
/// Anchored to the sidebar, overlays the content area.
pub const NotificationPanel = struct {
    hwnd: ?w32.HWND = null,
    parent_hwnd: ?w32.HWND = null,
    store: ?*NotificationStore = null,
    theme: Theme = Theme.dark(),
    scale: f32 = 1.0,
    visible: bool = false,
    scroll_offset: i32 = 0,

    pub const WINDOW_CLASS_NAME = "CmuxNotificationPanel";
    pub const PANEL_WIDTH: u32 = 320;
    pub const PANEL_MAX_HEIGHT: u32 = 480;
    pub const ENTRY_HEIGHT: u32 = 64;

    pub fn init() NotificationPanel {
        return .{};
    }

    pub fn deinit(self: *NotificationPanel) void {
        if (self.hwnd) |hwnd| {
            _ = w32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
    }

    /// Toggle panel visibility.
    pub fn toggle(self: *NotificationPanel) void {
        self.visible = !self.visible;
        if (self.hwnd) |hwnd| {
            _ = w32.ShowWindow(hwnd, if (self.visible) w32.SW_SHOW else w32.SW_HIDE);
            if (self.visible) {
                _ = w32.InvalidateRect(hwnd, null, 0);
                _ = w32.SetFocus(hwnd);
            }
        }
    }

    /// Show the panel.
    pub fn show(self: *NotificationPanel) void {
        if (!self.visible) {
            self.visible = true;
            if (self.hwnd) |hwnd| {
                _ = w32.ShowWindow(hwnd, w32.SW_SHOW);
                _ = w32.InvalidateRect(hwnd, null, 0);
                _ = w32.SetFocus(hwnd);
            }
        }
    }

    /// Hide the panel.
    pub fn hide(self: *NotificationPanel) void {
        if (self.visible) {
            self.visible = false;
            if (self.hwnd) |hwnd| {
                _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
            }
        }
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

        if (w32.RegisterClassExW(&wc) == 0) {
            return error.RegisterClassFailed;
        }
    }

    /// Create the panel as a popup window.
    pub fn createWindow(self: *NotificationPanel, parent: w32.HWND, hinstance: w32.HINSTANCE, x: i32, y: i32) !void {
        self.parent_hwnd = parent;

        const dpi = w32.GetDpiForWindow(parent);
        self.scale = @as(f32, @floatFromInt(dpi)) / 96.0;

        const width = Theme.scaled(PANEL_WIDTH, self.scale);
        const height = Theme.scaled(PANEL_MAX_HEIGHT, self.scale);

        self.hwnd = w32.CreateWindowExW(
            w32.WS_EX_TOOLWINDOW | w32.WS_EX_TOPMOST,
            toWide(WINDOW_CLASS_NAME),
            toWide("Notifications"),
            w32.WS_POPUP | w32.WS_BORDER,
            x, y,
            width, height,
            parent,
            null,
            hinstance,
            @intFromPtr(self),
        );

        if (self.hwnd == null) return error.CreateWindowFailed;
        // Start hidden
        _ = w32.ShowWindow(self.hwnd.?, w32.SW_HIDE);
    }

    fn panelWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.C) isize {
        switch (msg) {
            w32.WM_PAINT => {
                var ps: w32.PAINTSTRUCT = undefined;
                const hdc = w32.BeginPaint(hwnd, &ps);
                if (hdc) |dc| {
                    var rect: w32.RECT = undefined;
                    _ = w32.GetClientRect(hwnd, &rect);

                    // Dark background
                    const brush = w32.CreateSolidBrush(Theme.dark().sidebar_bg.toColorRef());
                    if (brush) |b| {
                        _ = w32.FillRect(dc, &rect, b);
                        _ = w32.DeleteObject(b);
                    }

                    // TODO: Render notification entries from the store
                    // Each entry: timestamp, title, body, read/unread indicator
                }
                _ = w32.EndPaint(hwnd, &ps);
                return 0;
            },
            w32.WM_KILLFOCUS => {
                // Hide panel when it loses focus
                _ = w32.ShowWindow(hwnd, w32.SW_HIDE);
                return 0;
            },
            w32.WM_ERASEBKGND => return 1,
            else => {},
        }
        return w32.DefWindowProcW(hwnd, msg, wparam, lparam);
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
