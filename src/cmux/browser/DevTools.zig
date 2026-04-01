const std = @import("std");
const WebView = @import("WebView.zig").WebView;

/// Manages DevTools (F12 / Ctrl+Shift+I) passthrough to the WebView2 instance.
pub const DevTools = struct {
    webview: ?*WebView = null,
    is_open: bool = false,

    pub fn init() DevTools {
        return .{};
    }

    /// Attach to a WebView instance.
    pub fn attach(self: *DevTools, webview: *WebView) void {
        self.webview = webview;
    }

    /// Toggle DevTools visibility.
    pub fn toggle(self: *DevTools) void {
        if (self.webview == null) return;

        if (self.is_open) {
            self.close();
        } else {
            self.open();
        }
    }

    /// Open the DevTools window.
    pub fn open(self: *DevTools) void {
        if (self.webview == null or self.is_open) return;
        // TODO: Call ICoreWebView2::OpenDevToolsWindow
        self.is_open = true;
    }

    /// Close the DevTools window.
    pub fn close(self: *DevTools) void {
        if (!self.is_open) return;
        // TODO: There's no direct close API; DevTools closes when its window is closed
        self.is_open = false;
    }

    /// Check if a key event should be intercepted for DevTools.
    pub fn shouldInterceptKey(vk: u16, ctrl: bool, shift: bool) bool {
        // F12
        if (vk == 0x7B) return true;
        // Ctrl+Shift+I
        if (ctrl and shift and vk == 0x49) return true;
        return false;
    }
};
