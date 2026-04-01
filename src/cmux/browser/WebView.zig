const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("../../apprt/win32/win32.zig");

/// Hosts a WebView2 (Edge/Chromium) instance as a child HWND.
/// Used as a leaf node in the split pane tree for the embedded browser.
///
/// WebView2 lifecycle:
///   1. CreateCoreWebView2EnvironmentWithOptions (async)
///   2. Environment.CreateCoreWebView2Controller (async)
///   3. Controller.get_CoreWebView2 → ready
///
/// Since WebView2 uses COM and asynchronous callbacks, initialization is
/// driven by the Win32 message loop (callbacks post messages back).
pub const WebView = struct {
    allocator: Allocator,

    /// Host HWND that contains the WebView2 control.
    hwnd: ?w32.HWND = null,
    parent_hwnd: ?w32.HWND = null,

    /// WebView2 COM interface pointers (opaque until COM wrappers are implemented).
    environment: ?*anyopaque = null,
    controller: ?*anyopaque = null,
    webview: ?*anyopaque = null,

    /// Current URL.
    url: [2048]u8 = [_]u8{0} ** 2048,
    url_len: u16 = 0,

    /// Current page title.
    title: [256]u8 = [_]u8{0} ** 256,
    title_len: u16 = 0,

    /// Initialization state.
    state: InitState = .uninitialized,

    /// Navigation state.
    can_go_back: bool = false,
    can_go_forward: bool = false,
    is_loading: bool = false,

    pub const InitState = enum {
        uninitialized,
        creating_environment,
        creating_controller,
        ready,
        failed,
    };

    pub const WINDOW_CLASS_NAME = "CmuxBrowser";

    /// Custom messages for WebView2 async callbacks.
    pub const WM_WEBVIEW_ENV_CREATED = w32.WM_USER + 400;
    pub const WM_WEBVIEW_CONTROLLER_CREATED = w32.WM_USER + 401;
    pub const WM_WEBVIEW_NAV_COMPLETED = w32.WM_USER + 402;
    pub const WM_WEBVIEW_TITLE_CHANGED = w32.WM_USER + 403;

    pub fn init(allocator: Allocator) WebView {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *WebView) void {
        // Release COM objects
        self.releaseWebView();
        if (self.hwnd) |hwnd| {
            _ = w32.DestroyWindow(hwnd);
            self.hwnd = null;
        }
    }

    /// Create the host HWND and begin WebView2 initialization.
    pub fn createWindow(self: *WebView, parent: w32.HWND, hinstance: w32.HINSTANCE, rect: w32.RECT) !void {
        self.parent_hwnd = parent;

        self.hwnd = w32.CreateWindowExW(
            0,
            toWide(WINDOW_CLASS_NAME),
            null,
            w32.WS_CHILD | w32.WS_VISIBLE | w32.WS_CLIPCHILDREN,
            rect.left,
            rect.top,
            rect.right - rect.left,
            rect.bottom - rect.top,
            parent,
            null,
            hinstance,
            @intFromPtr(self),
        );

        if (self.hwnd == null) return error.CreateWindowFailed;

        // Begin async WebView2 initialization
        self.initWebView2();
    }

    /// Navigate to a URL.
    pub fn navigate(self: *WebView, url: []const u8) void {
        const len = @min(url.len, self.url.len);
        @memcpy(self.url[0..len], url[0..len]);
        self.url_len = @intCast(len);

        if (self.state != .ready) return;

        // TODO: Call ICoreWebView2::Navigate with the URL
        self.is_loading = true;
    }

    /// Go back in history.
    pub fn goBack(self: *WebView) void {
        if (!self.can_go_back or self.state != .ready) return;
        // TODO: Call ICoreWebView2::GoBack
    }

    /// Go forward in history.
    pub fn goForward(self: *WebView) void {
        if (!self.can_go_forward or self.state != .ready) return;
        // TODO: Call ICoreWebView2::GoForward
    }

    /// Reload the current page.
    pub fn reload(self: *WebView) void {
        if (self.state != .ready) return;
        // TODO: Call ICoreWebView2::Reload
    }

    /// Execute JavaScript in the page context.
    pub fn executeScript(self: *WebView, script: []const u8) void {
        if (self.state != .ready) return;
        _ = script;
        // TODO: Call ICoreWebView2::ExecuteScript
    }

    /// Resize the WebView to fill the host HWND.
    pub fn resize(self: *WebView, width: i32, height: i32) void {
        if (self.hwnd) |hwnd| {
            _ = w32.MoveWindow(hwnd, 0, 0, width, height, 1);
        }
        // TODO: Call ICoreWebView2Controller::put_Bounds
    }

    /// Get the current URL.
    pub fn getUrl(self: *const WebView) []const u8 {
        return self.url[0..self.url_len];
    }

    /// Get the current page title.
    pub fn getTitle(self: *const WebView) []const u8 {
        return self.title[0..self.title_len];
    }

    /// Register the browser host window class.
    pub fn registerClass(hinstance: w32.HINSTANCE) !void {
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = 0,
            .lpfnWndProc = browserWndProc,
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

    // --- Private ---

    fn initWebView2(self: *WebView) void {
        self.state = .creating_environment;
        // TODO: Call CreateCoreWebView2EnvironmentWithOptions
        // The callback will post WM_WEBVIEW_ENV_CREATED to self.hwnd
        _ = self;
    }

    fn releaseWebView(self: *WebView) void {
        // TODO: Release ICoreWebView2, ICoreWebView2Controller, ICoreWebView2Environment
        self.webview = null;
        self.controller = null;
        self.environment = null;
        self.state = .uninitialized;
    }

    fn browserWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.C) isize {
        switch (msg) {
            WM_WEBVIEW_ENV_CREATED => {
                // TODO: Create controller from environment
                return 0;
            },
            WM_WEBVIEW_CONTROLLER_CREATED => {
                // TODO: Get CoreWebView2 from controller, navigate to initial URL
                return 0;
            },
            w32.WM_SIZE => {
                // TODO: Resize WebView2 controller bounds
                return 0;
            },
            w32.WM_DESTROY => {
                return 0;
            },
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
