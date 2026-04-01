const std = @import("std");
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;
const Color = @import("Theme.zig").Color;

/// A thin status bar at the bottom of the content area that shows
/// git branch, listening ports, and CWD for the active workspace.
pub const StatusBar = struct {
    hwnd: ?w32.HWND = null,
    parent_hwnd: ?w32.HWND = null,
    theme: Theme = Theme.dark(),
    scale: f32 = 1.0,
    visible: bool = true,

    // Display data (copied from active workspace)
    git_branch: [64]u8 = [_]u8{0} ** 64,
    git_branch_len: u8 = 0,
    cwd: [256]u8 = [_]u8{0} ** 256,
    cwd_len: u16 = 0,
    ports: [8]u16 = [_]u16{0} ** 8,
    port_count: u8 = 0,
    shell_name: [32]u8 = [_]u8{0} ** 32,
    shell_name_len: u8 = 0,

    pub const WINDOW_CLASS_NAME = "CmuxStatusBar";

    pub fn init() StatusBar {
        return .{};
    }

    /// Get the height the status bar occupies.
    pub fn getHeight(self: *const StatusBar) i32 {
        if (!self.visible) return 0;
        return Theme.scaled(Theme.status_bar_height, self.scale);
    }

    /// Update displayed metadata from the active workspace.
    pub fn update(
        self: *StatusBar,
        git_branch: []const u8,
        cwd: []const u8,
        ports: []const u16,
        shell_name: []const u8,
    ) void {
        const gl = @min(git_branch.len, self.git_branch.len);
        @memcpy(self.git_branch[0..gl], git_branch[0..gl]);
        self.git_branch_len = @intCast(gl);

        const cl = @min(cwd.len, self.cwd.len);
        @memcpy(self.cwd[0..cl], cwd[0..cl]);
        self.cwd_len = @intCast(cl);

        const pc = @min(ports.len, self.ports.len);
        @memcpy(self.ports[0..pc], ports[0..pc]);
        self.port_count = @intCast(pc);

        const sl = @min(shell_name.len, self.shell_name.len);
        @memcpy(self.shell_name[0..sl], shell_name[0..sl]);
        self.shell_name_len = @intCast(sl);

        if (self.hwnd) |hwnd| {
            _ = w32.InvalidateRect(hwnd, null, 0);
        }
    }

    /// Register the status bar window class.
    pub fn registerClass(hinstance: w32.HINSTANCE) !void {
        const wc = w32.WNDCLASSEXW{
            .cbSize = @sizeOf(w32.WNDCLASSEXW),
            .style = w32.CS_HREDRAW | w32.CS_VREDRAW,
            .lpfnWndProc = statusBarWndProc,
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

    fn statusBarWndProc(hwnd: w32.HWND, msg: u32, wparam: usize, lparam: isize) callconv(.C) isize {
        switch (msg) {
            w32.WM_PAINT => {
                var ps: w32.PAINTSTRUCT = undefined;
                const hdc = w32.BeginPaint(hwnd, &ps);
                if (hdc) |dc| {
                    var rect: w32.RECT = undefined;
                    _ = w32.GetClientRect(hwnd, &rect);
                    // Dark background
                    const brush = w32.CreateSolidBrush(Theme.dark().status_bar_bg.toColorRef());
                    if (brush) |b| {
                        _ = w32.FillRect(dc, &rect, b);
                        _ = w32.DeleteObject(b);
                    }
                    // TODO: Draw git branch, CWD, ports text with DirectWrite
                }
                _ = w32.EndPaint(hwnd, &ps);
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
