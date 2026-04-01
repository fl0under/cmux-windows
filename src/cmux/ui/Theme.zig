const std = @import("std");
const w32 = @import("../../apprt/win32/win32.zig");

/// Color and styling constants for the cmux UI shell.
/// All colors are ARGB format for Direct2D compatibility.
pub const Theme = struct {
    // Sidebar
    sidebar_bg: Color = Color.fromRgb(0x1E, 0x1E, 0x2E), // Dark background
    sidebar_tab_bg: Color = Color.fromRgb(0x28, 0x28, 0x3C),
    sidebar_tab_active_bg: Color = Color.fromRgb(0x3A, 0x3A, 0x5C),
    sidebar_tab_hover_bg: Color = Color.fromRgb(0x31, 0x31, 0x4A),
    sidebar_text: Color = Color.fromRgb(0xCD, 0xD6, 0xF4),
    sidebar_text_dim: Color = Color.fromRgb(0x6C, 0x70, 0x86),
    sidebar_separator: Color = Color.fromRgb(0x45, 0x47, 0x5A),

    // Notification
    notification_ring: Color = Color.fromRgb(0x89, 0xB4, 0xFA), // Blue ring
    notification_badge_bg: Color = Color.fromRgb(0xF3, 0x8B, 0xA8), // Pink badge
    notification_badge_text: Color = Color.fromRgb(0x1E, 0x1E, 0x2E),
    unread_dot: Color = Color.fromRgb(0x89, 0xB4, 0xFA),

    // Split pane
    split_divider: Color = Color.fromRgb(0x45, 0x47, 0x5A),
    split_divider_active: Color = Color.fromRgb(0x89, 0xB4, 0xFA),
    focus_border: Color = Color.fromRgb(0x89, 0xB4, 0xFA),

    // Status bar
    status_bar_bg: Color = Color.fromRgb(0x18, 0x18, 0x25),
    status_text: Color = Color.fromRgb(0xA6, 0xAD, 0xC8),

    // General
    accent: Color = Color.fromRgb(0x89, 0xB4, 0xFA),
    error_color: Color = Color.fromRgb(0xF3, 0x8B, 0xA8),
    success: Color = Color.fromRgb(0xA6, 0xE3, 0xA1),
    warning: Color = Color.fromRgb(0xF9, 0xE2, 0xAF),

    // Layout constants (in logical pixels, scaled by DPI)
    pub const sidebar_width: u32 = 240;
    pub const sidebar_min_width: u32 = 48; // Collapsed icon-only mode
    pub const sidebar_tab_height: u32 = 56;
    pub const sidebar_tab_padding: u32 = 8;
    pub const sidebar_icon_size: u32 = 20;
    pub const split_divider_width: u32 = 4;
    pub const notification_ring_width: u32 = 3;
    pub const notification_badge_size: u32 = 16;
    pub const status_bar_height: u32 = 24;
    pub const tab_corner_radius: f32 = 6.0;

    // Font
    pub const font_family = "Segoe UI";
    pub const font_size_tab: f32 = 13.0;
    pub const font_size_status: f32 = 11.0;
    pub const font_size_badge: f32 = 10.0;

    /// Get the default dark theme.
    pub fn dark() Theme {
        return .{};
    }

    /// Scale a layout value by DPI factor.
    pub fn scaled(value: u32, dpi_scale: f32) i32 {
        return @intFromFloat(@as(f32, @floatFromInt(value)) * dpi_scale);
    }
};

/// ARGB color representation compatible with Direct2D.
pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1.0,

    pub fn fromRgb(r: u8, g: u8, b: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
        };
    }

    pub fn fromRgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{
            .r = @as(f32, @floatFromInt(r)) / 255.0,
            .g = @as(f32, @floatFromInt(g)) / 255.0,
            .b = @as(f32, @floatFromInt(b)) / 255.0,
            .a = @as(f32, @floatFromInt(a)) / 255.0,
        };
    }

    /// Convert to Win32 COLORREF (0x00BBGGRR).
    pub fn toColorRef(self: Color) u32 {
        const r: u32 = @intFromFloat(self.r * 255.0);
        const g: u32 = @intFromFloat(self.g * 255.0);
        const b: u32 = @intFromFloat(self.b * 255.0);
        return r | (g << 8) | (b << 16);
    }
};

test "Color.fromRgb" {
    const c = Color.fromRgb(0xFF, 0x00, 0x80);
    try std.testing.expectApproxEqAbs(c.r, 1.0, 0.01);
    try std.testing.expectApproxEqAbs(c.g, 0.0, 0.01);
    try std.testing.expectApproxEqAbs(c.b, 0.502, 0.01);
    try std.testing.expectApproxEqAbs(c.a, 1.0, 0.01);
}

test "Color.toColorRef" {
    const c = Color.fromRgb(0xFF, 0x00, 0x80);
    const cr = c.toColorRef();
    try std.testing.expectEqual(@as(u32, 0x008000FF), cr);
}

test "Theme.scaled" {
    const result = Theme.scaled(240, 1.5);
    try std.testing.expectEqual(@as(i32, 360), result);
}
