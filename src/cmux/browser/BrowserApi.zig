const std = @import("std");
const Allocator = std.mem.Allocator;
const WebView = @import("WebView.zig").WebView;

/// Scriptable browser API for AI agent interaction.
/// Provides accessibility tree snapshots, element interaction (click, fill),
/// and JavaScript evaluation via WebView2's CDP and ExecuteScript APIs.
///
/// This mirrors cmux macOS's agent-browser port, adapted for WebView2.
pub const BrowserApi = struct {
    allocator: Allocator,
    webview: ?*WebView = null,

    pub fn init(allocator: Allocator) BrowserApi {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *BrowserApi) void {
        _ = self;
    }

    /// Attach to a WebView instance.
    pub fn attach(self: *BrowserApi, webview: *WebView) void {
        self.webview = webview;
    }

    /// Get a snapshot of the page's accessibility tree.
    /// Uses CDP (Chrome DevTools Protocol) via WebView2's
    /// ICoreWebView2DevToolsProtocolEventReceiver.
    ///
    /// Returns a JSON string representing the a11y tree.
    pub fn getAccessibilityTree(self: *BrowserApi) ![]u8 {
        const wv = self.webview orelse return error.NoWebView;
        _ = wv;

        // TODO: Call CDP Accessibility.getFullAXTree via
        // ICoreWebView2::CallDevToolsProtocolMethod
        // For now, return a placeholder
        return try self.allocator.dupe(u8, "[]");
    }

    /// Click an element by CSS selector.
    pub fn click(self: *BrowserApi, selector: []const u8) !void {
        const wv = self.webview orelse return error.NoWebView;

        // Generate JS to find element and dispatch click event
        var script_buf: [1024]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            \\document.querySelector('{s}')?.click()
        , .{selector}) catch return error.SelectorTooLong;

        wv.executeScript(script);
    }

    /// Fill an input element with text by CSS selector.
    pub fn fill(self: *BrowserApi, selector: []const u8, value: []const u8) !void {
        const wv = self.webview orelse return error.NoWebView;

        var script_buf: [2048]u8 = undefined;
        const script = std.fmt.bufPrint(&script_buf,
            \\(function() {{
            \\  var el = document.querySelector('{s}');
            \\  if (el) {{
            \\    el.value = '{s}';
            \\    el.dispatchEvent(new Event('input', {{ bubbles: true }}));
            \\    el.dispatchEvent(new Event('change', {{ bubbles: true }}));
            \\  }}
            \\}})()
        , .{ selector, value }) catch return error.InputTooLong;

        wv.executeScript(script);
    }

    /// Evaluate arbitrary JavaScript and return the result as a string.
    pub fn evaluate(self: *BrowserApi, script: []const u8) ![]u8 {
        const wv = self.webview orelse return error.NoWebView;
        _ = wv;
        _ = script;

        // TODO: Use ICoreWebView2::ExecuteScript with a callback
        // to capture the result string
        return try self.allocator.dupe(u8, "null");
    }

    /// Get the current URL.
    pub fn getCurrentUrl(self: *BrowserApi) ?[]const u8 {
        const wv = self.webview orelse return null;
        const url = wv.getUrl();
        if (url.len == 0) return null;
        return url;
    }

    /// Get the current page title.
    pub fn getCurrentTitle(self: *BrowserApi) ?[]const u8 {
        const wv = self.webview orelse return null;
        const title = wv.getTitle();
        if (title.len == 0) return null;
        return title;
    }

    /// Navigate to a URL.
    pub fn navigateTo(self: *BrowserApi, url: []const u8) !void {
        const wv = self.webview orelse return error.NoWebView;
        wv.navigate(url);
    }
};
