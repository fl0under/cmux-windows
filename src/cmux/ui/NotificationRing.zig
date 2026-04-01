const std = @import("std");
const w32 = @import("../../apprt/win32/win32.zig");
const Theme = @import("Theme.zig").Theme;
const Color = @import("Theme.zig").Color;

/// Draws an animated blue ring overlay around a terminal surface when a
/// notification fires. The ring pulses (2-frame animation, ~2s duration)
/// then fades out.
pub const NotificationRing = struct {
    /// Whether the ring is currently showing.
    active: bool = false,
    /// Target HWND to draw the ring around.
    target_hwnd: ?w32.HWND = null,
    /// Animation start time (tick count).
    start_tick: u64 = 0,
    /// Duration of the ring animation in milliseconds.
    duration_ms: u64 = 2000,
    /// Ring color.
    color: Color = Theme.dark().notification_ring,
    /// Ring width in logical pixels.
    width: u32 = Theme.notification_ring_width,
    /// DPI scale factor.
    scale: f32 = 1.0,

    /// Timer ID used for animation frames.
    pub const TIMER_ID: usize = 0xCM01;

    /// Start the ring animation on a surface.
    pub fn activate(self: *NotificationRing, hwnd: w32.HWND) void {
        self.target_hwnd = hwnd;
        self.active = true;
        self.start_tick = @intCast(w32.GetTickCount64());

        // Set a timer for animation updates (~60fps = 16ms)
        _ = w32.SetTimer(hwnd, TIMER_ID, 16, null);
    }

    /// Stop the ring animation.
    pub fn deactivate(self: *NotificationRing) void {
        if (self.target_hwnd) |hwnd| {
            _ = w32.KillTimer(hwnd, TIMER_ID);
        }
        self.active = false;
        self.target_hwnd = null;
    }

    /// Called on each animation tick. Returns false when animation is complete.
    pub fn tick(self: *NotificationRing) bool {
        if (!self.active) return false;

        const now: u64 = @intCast(w32.GetTickCount64());
        const elapsed = now - self.start_tick;

        if (elapsed >= self.duration_ms) {
            self.deactivate();
            return false;
        }

        // Trigger repaint
        if (self.target_hwnd) |hwnd| {
            _ = w32.InvalidateRect(hwnd, null, 0);
        }
        return true;
    }

    /// Calculate the current alpha based on animation progress.
    /// Uses a pulse pattern: fade in → hold → fade out.
    pub fn currentAlpha(self: *const NotificationRing) f32 {
        if (!self.active) return 0.0;

        const now: u64 = @intCast(w32.GetTickCount64());
        const elapsed = now - self.start_tick;
        const progress = @as(f32, @floatFromInt(elapsed)) / @as(f32, @floatFromInt(self.duration_ms));

        // Pulse pattern: sin curve for smooth fade in/out
        return @sin(progress * std.math.pi) * 0.8;
    }

    /// Draw the ring overlay on the given HDC using GDI.
    /// For MVP; will be replaced with Direct2D for proper anti-aliased rendering.
    pub fn paint(self: *const NotificationRing, hdc: w32.HDC, rect: w32.RECT) void {
        if (!self.active) return;

        const alpha = self.currentAlpha();
        if (alpha < 0.01) return;

        const ring_w = Theme.scaled(self.width, self.scale);

        // Approximate alpha by blending the ring color with a base intensity
        const intensity: u8 = @intFromFloat(alpha * 255.0);
        const r: u8 = @intFromFloat(self.color.r * @as(f32, @floatFromInt(intensity)));
        const g: u8 = @intFromFloat(self.color.g * @as(f32, @floatFromInt(intensity)));
        const b: u8 = @intFromFloat(self.color.b * @as(f32, @floatFromInt(intensity)));
        const color_ref = @as(u32, r) | (@as(u32, g) << 8) | (@as(u32, b) << 16);

        const pen = w32.CreatePen(w32.PS_SOLID, ring_w, color_ref);
        if (pen) |p| {
            const old_pen = w32.SelectObject(hdc, p);
            const old_brush = w32.SelectObject(hdc, w32.GetStockObject(w32.NULL_BRUSH));

            _ = w32.Rectangle(
                hdc,
                rect.left + @divTrunc(ring_w, 2),
                rect.top + @divTrunc(ring_w, 2),
                rect.right - @divTrunc(ring_w, 2),
                rect.bottom - @divTrunc(ring_w, 2),
            );

            _ = w32.SelectObject(hdc, old_brush);
            _ = w32.SelectObject(hdc, old_pen);
            _ = w32.DeleteObject(p);
        }
    }
};
