const std = @import("std");
const w32 = @import("../../apprt/win32/win32.zig");

/// Bridge to the Windows toast notification API.
/// For MVP, uses Shell_NotifyIcon tray balloon notifications.
/// Will be upgraded to full ToastNotificationManager with AppUserModelID.
pub const ToastBridge = struct {
    /// Whether the notification tray icon has been created.
    tray_icon_created: bool = false,
    /// The HWND that receives notification callbacks.
    callback_hwnd: ?w32.HWND = null,

    pub const WM_TRAY_CALLBACK = w32.WM_USER + 200;
    pub const TRAY_ICON_ID: u32 = 1;

    pub fn init() ToastBridge {
        return .{};
    }

    pub fn deinit(self: *ToastBridge) void {
        if (self.tray_icon_created) {
            self.removeTrayIcon();
        }
    }

    /// Create the system tray icon (required for balloon notifications).
    pub fn createTrayIcon(self: *ToastBridge, hwnd: w32.HWND, hicon: ?w32.HICON) void {
        self.callback_hwnd = hwnd;

        var nid = std.mem.zeroes(NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = TRAY_ICON_ID;
        nid.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
        nid.uCallbackMessage = WM_TRAY_CALLBACK;
        nid.hIcon = hicon;

        // Set tooltip: "cmux"
        const tip = comptime toWide16("cmux");
        @memcpy(nid.szTip[0..tip.len], &tip);

        _ = Shell_NotifyIconW(NIM_ADD, &nid);
        self.tray_icon_created = true;
    }

    /// Remove the system tray icon.
    pub fn removeTrayIcon(self: *ToastBridge) void {
        if (!self.tray_icon_created) return;
        const hwnd = self.callback_hwnd orelse return;

        var nid = std.mem.zeroes(NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = TRAY_ICON_ID;

        _ = Shell_NotifyIconW(NIM_DELETE, &nid);
        self.tray_icon_created = false;
    }

    /// Show a balloon (toast-like) notification.
    pub fn showNotification(self: *ToastBridge, title: []const u8, body: []const u8) void {
        if (!self.tray_icon_created) return;
        const hwnd = self.callback_hwnd orelse return;

        var nid = std.mem.zeroes(NOTIFYICONDATAW);
        nid.cbSize = @sizeOf(NOTIFYICONDATAW);
        nid.hWnd = hwnd;
        nid.uID = TRAY_ICON_ID;
        nid.uFlags = NIF_INFO;
        nid.dwInfoFlags = NIIF_INFO;
        nid.uTimeout = 5000; // 5 seconds

        // Convert title to UTF-16
        var title_buf: [64]u16 = [_]u16{0} ** 64;
        const title_len = @min(title.len, title_buf.len - 1);
        for (0..title_len) |i| {
            title_buf[i] = title[i];
        }
        @memcpy(nid.szInfoTitle[0..title_len], title_buf[0..title_len]);

        // Convert body to UTF-16
        var body_buf: [256]u16 = [_]u16{0} ** 256;
        const body_len = @min(body.len, body_buf.len - 1);
        for (0..body_len) |i| {
            body_buf[i] = body[i];
        }
        @memcpy(nid.szInfo[0..body_len], body_buf[0..body_len]);

        _ = Shell_NotifyIconW(NIM_MODIFY, &nid);
    }

    // --- Win32 Shell notification types ---

    const NIM_ADD: u32 = 0x00000000;
    const NIM_MODIFY: u32 = 0x00000001;
    const NIM_DELETE: u32 = 0x00000002;
    const NIF_MESSAGE: u32 = 0x00000001;
    const NIF_ICON: u32 = 0x00000002;
    const NIF_TIP: u32 = 0x00000004;
    const NIF_INFO: u32 = 0x00000010;
    const NIIF_INFO: u32 = 0x00000001;

    const NOTIFYICONDATAW = extern struct {
        cbSize: u32 = 0,
        hWnd: ?w32.HWND = null,
        uID: u32 = 0,
        uFlags: u32 = 0,
        uCallbackMessage: u32 = 0,
        hIcon: ?w32.HICON = null,
        szTip: [128]u16 = [_]u16{0} ** 128,
        dwState: u32 = 0,
        dwStateMask: u32 = 0,
        szInfo: [256]u16 = [_]u16{0} ** 256,
        uTimeout: u32 = 0,
        szInfoTitle: [64]u16 = [_]u16{0} ** 64,
        dwInfoFlags: u32 = 0,
        guidItem: [16]u8 = [_]u8{0} ** 16,
        hBalloonIcon: ?w32.HICON = null,
    };

    extern "shell32" fn Shell_NotifyIconW(dwMessage: u32, lpData: *NOTIFYICONDATAW) callconv(.C) i32;

    fn toWide16(comptime s: []const u8) [s.len]u16 {
        var buf: [s.len]u16 = undefined;
        for (s, 0..) |c, i| {
            buf[i] = c;
        }
        return buf;
    }
};
