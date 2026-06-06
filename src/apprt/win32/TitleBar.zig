//! Custom-drawn titlebar with integrated tabs for the win32 apprt.
//!
//! This module owns no HWND. Window.zig forwards WM_PAINT and mouse
//! messages to it; it computes layout/hit-tests and paints onto the
//! HDC it is given. Shapes are drawn with the GDI+ flat C API (for
//! anti-aliased rounded tab tops) and text with GDI DrawTextW
//! (ClearType). All painting is double-buffered.
//!
//! Design spec: docs/superpowers/specs/2026-06-06-win32-titlebar-tabs-design.md
const TitleBar = @This();

const std = @import("std");
const sys = @import("sys.zig");

const RECT = sys.RECT;

/// Element currently hovered by the mouse (for highlight rendering).
hover: Element = .none,
/// Element the left button went down on. The action fires on button-up
/// only if the cursor is still over the same element.
pressed: Element = .none,
/// Whether TrackMouseEvent(TME_LEAVE) is currently armed.
tracking_mouse: bool = false,
/// Whether the top-level window is active (inactive dims the text).
window_active: bool = true,

// Cached GDI fonts, recreated when the DPI changes.
text_font: ?*anyopaque = null,
glyph_font: ?*anyopaque = null,
fonts_dpi: u32 = 0,

pub const Element = union(enum) {
    none,
    /// Empty area: lets WM_NCHITTEST report HTCAPTION (window drag).
    caption,
    tab: usize,
    tab_close: usize,
    new_tab,
    minimize,
    maximize,
    close,

    pub fn eql(a: Element, b: Element) bool {
        return std.meta.eql(a, b);
    }
};

pub fn deinit(self: *TitleBar) void {
    if (self.text_font) |f| _ = sys.DeleteObject(f);
    if (self.glyph_font) |f| _ = sys.DeleteObject(f);
    self.* = .{};
}

// ---------------------------------------------------------------------------
// Colors
// ---------------------------------------------------------------------------

pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,

    /// GDI COLORREF is 0x00BBGGRR.
    pub fn colorref(self: Rgb) u32 {
        return @as(u32, self.r) | (@as(u32, self.g) << 8) | (@as(u32, self.b) << 16);
    }

    /// GDI+ ARGB is 0xAARRGGBB.
    pub fn argb(self: Rgb) u32 {
        return 0xFF000000 | (@as(u32, self.r) << 16) | (@as(u32, self.g) << 8) | @as(u32, self.b);
    }

    /// True if this color is "dark" (used for the DWM dark-mode hint).
    pub fn isDark(self: Rgb) bool {
        const lum: u32 = (@as(u32, self.r) * 299 + @as(u32, self.g) * 587 + @as(u32, self.b) * 114) / 1000;
        return lum < 128;
    }
};

/// Move each channel `pct`% toward `to`.
fn blendChannel(from: u8, to: u8, pct: u8) u8 {
    const f: i32 = from;
    const t: i32 = to;
    return @intCast(f + @divTrunc((t - f) * @as(i32, pct), 100));
}

pub fn blend(from: Rgb, to: Rgb, pct: u8) Rgb {
    return .{
        .r = blendChannel(from.r, to.r, pct),
        .g = blendChannel(from.g, to.g, pct),
        .b = blendChannel(from.b, to.b, pct),
    };
}

pub fn darken(c: Rgb, pct: u8) Rgb {
    return blend(c, .{ .r = 0, .g = 0, .b = 0 }, pct);
}

pub fn lighten(c: Rgb, pct: u8) Rgb {
    return blend(c, .{ .r = 255, .g = 255, .b = 255 }, pct);
}

/// All colors are derived from the configured terminal background and
/// foreground so the bar follows the user's theme (spec: テーマ追従).
pub const Palette = struct {
    bar_bg: Rgb,
    active_tab: Rgb,
    hover_tab: Rgb,
    text_active: Rgb,
    text_inactive: Rgb,
    btn_hover: Rgb,
    close_hover: Rgb,

    pub fn derive(bg: Rgb, fg: Rgb) Palette {
        const bar = darken(bg, 25);
        return .{
            .bar_bg = bar,
            .active_tab = bg,
            .hover_tab = lighten(bar, 8),
            .text_active = fg,
            .text_inactive = blend(fg, bg, 50),
            .btn_hover = lighten(bar, 10),
            // Windows-standard caption close red.
            .close_hover = .{ .r = 0xE8, .g = 0x11, .b = 0x23 },
        };
    }

    /// Text color accounting for window activation state.
    pub fn textColor(self: *const Palette, active_tab: bool, window_active: bool) Rgb {
        const base = if (active_tab) self.text_active else self.text_inactive;
        // Dim everything further when the window is not focused.
        return if (window_active) base else blend(base, self.active_tab, 40);
    }
};

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// Scale a 96-dpi design value to the window's DPI.
fn s(dpi: u32, v: i32) i32 {
    return @divTrunc(v * @as(i32, @intCast(dpi)), 96);
}

/// Bar height in client pixels for the given DPI.
pub fn barHeight(dpi: u32) i32 {
    return s(dpi, 38);
}

pub const Layout = struct {
    dpi: u32,
    width: i32,
    height: i32,
    /// Top margin above tabs; doubles as a window-drag strip when the
    /// window is not maximized.
    tab_top: i32,
    /// Left zone reserved for the app icon.
    icon_w: i32,
    tab_w: i32,
    tab_count: usize,
    /// x of the "+" button (right after the last tab).
    plus_x: i32,
    plus_w: i32,
    /// x of the caption button group (min/max/close), each btn_w wide.
    buttons_x: i32,
    btn_w: i32,
    radius: i32,
    /// False when only one tab exists: no tab shapes, title text only.
    show_tabs: bool,

    pub fn compute(dpi: u32, width: i32, tab_count: usize) Layout {
        const btn_w = s(dpi, 46);
        const icon_w = s(dpi, 40);
        const plus_w = s(dpi, 34);
        const buttons_x = width - 3 * btn_w;
        const show_tabs = tab_count > 1;

        var tab_w: i32 = 0;
        if (show_tabs) {
            const avail = buttons_x - icon_w - plus_w;
            const n: i32 = @intCast(tab_count);
            // Spec asks min 110 normally; under heavy pressure we keep
            // shrinking (stronger ellipsis) instead of overflowing
            // under the caption buttons (no scrolling in scope).
            tab_w = std.math.clamp(@divTrunc(@max(avail, 0), n), s(dpi, 60), s(dpi, 220));
        }

        const n: i32 = @intCast(tab_count);
        return .{
            .dpi = dpi,
            .width = width,
            .height = barHeight(dpi),
            .tab_top = s(dpi, 6),
            .icon_w = icon_w,
            .tab_w = tab_w,
            .tab_count = tab_count,
            .plus_x = if (show_tabs) icon_w + n * tab_w else icon_w,
            .plus_w = plus_w,
            .buttons_x = buttons_x,
            .btn_w = btn_w,
            .radius = s(dpi, 8),
            .show_tabs = show_tabs,
        };
    }

    pub fn tabRect(self: *const Layout, i: usize) RECT {
        const idx: i32 = @intCast(i);
        return .{
            .left = self.icon_w + idx * self.tab_w,
            .top = self.tab_top,
            .right = self.icon_w + (idx + 1) * self.tab_w,
            .bottom = self.height,
        };
    }

    /// Close ("✕") hot zone inside a tab.
    pub fn tabCloseRect(self: *const Layout, i: usize) RECT {
        const r = self.tabRect(i);
        const size = s(self.dpi, 18);
        const margin = s(self.dpi, 8);
        const cy = @divTrunc(r.top + r.bottom - size, 2);
        return .{
            .left = r.right - margin - size,
            .top = cy,
            .right = r.right - margin,
            .bottom = cy + size,
        };
    }

    fn inRect(r: RECT, x: i32, y: i32) bool {
        return x >= r.left and x < r.right and y >= r.top and y < r.bottom;
    }

    /// Map a client-space point to a titlebar element. `maximized`
    /// turns the top drag margin into tab surface (spec: 最大化時は
    /// タブ上余白をタブクリックに割当).
    pub fn hitTest(self: *const Layout, x: i32, y: i32, maximized: bool) Element {
        if (y < 0 or y >= self.height or x < 0 or x >= self.width) return .none;

        // Caption buttons span the full bar height.
        if (x >= self.buttons_x) {
            const rel = @divTrunc(x - self.buttons_x, self.btn_w);
            return switch (rel) {
                0 => .minimize,
                1 => .maximize,
                else => .close,
            };
        }

        if (!self.show_tabs) return .caption;

        // Top margin acts as drag area unless maximized.
        if (y < self.tab_top and !maximized) return .caption;

        if (x >= self.icon_w and x < self.plus_x) {
            const i: usize = @intCast(@divTrunc(x - self.icon_w, self.tab_w));
            if (i >= self.tab_count) return .caption;
            if (inRect(self.tabCloseRect(i), x, y)) return .{ .tab_close = i };
            return .{ .tab = i };
        }

        if (x >= self.plus_x and x < self.plus_x + self.plus_w) return .new_tab;

        return .caption;
    }
};

test "palette derives theme-relative colors" {
    const bg: Rgb = .{ .r = 0x28, .g = 0x2C, .b = 0x34 };
    const fg: Rgb = .{ .r = 0xFF, .g = 0xFF, .b = 0xFF };
    const p = Palette.derive(bg, fg);
    try std.testing.expect(p.active_tab.r == bg.r and p.active_tab.b == bg.b);
    // bar is darker than the terminal background
    try std.testing.expect(p.bar_bg.r < bg.r);
    // inactive text sits between fg and bg
    try std.testing.expect(p.text_inactive.r < fg.r and p.text_inactive.r > bg.r);
    try std.testing.expect(bg.isDark());
    try std.testing.expect(!fg.isDark());
}

test "layout hit testing" {
    const l = Layout.compute(96, 800, 3);
    try std.testing.expectEqual(@as(i32, 38), l.height);
    try std.testing.expectEqual(@as(i32, 800 - 3 * 46), l.buttons_x);
    // top margin drags the window...
    try std.testing.expect(Element.eql(l.hitTest(200, 2, false), .caption));
    // ...but is tab surface when maximized
    try std.testing.expect(Element.eql(l.hitTest(l.icon_w + 1, 2, true), .{ .tab = 0 }));
    // middle of the second tab
    const r1 = l.tabRect(1);
    try std.testing.expect(Element.eql(
        l.hitTest(r1.left + 5, 20, false),
        .{ .tab = 1 },
    ));
    // caption buttons
    try std.testing.expect(Element.eql(l.hitTest(800 - 1, 10, false), .close));
    try std.testing.expect(Element.eql(l.hitTest(800 - 3 * 46 + 1, 10, false), .minimize));
    // single tab: everything between icon and buttons is caption
    const single = Layout.compute(96, 800, 1);
    try std.testing.expect(!single.show_tabs);
    try std.testing.expect(Element.eql(single.hitTest(300, 20, false), .caption));
}

test "layout clamps tab width under pressure" {
    const l = Layout.compute(96, 500, 10);
    try std.testing.expectEqual(@as(i32, 60), l.tab_w);
    const wide = Layout.compute(96, 3000, 2);
    try std.testing.expectEqual(@as(i32, 220), wide.tab_w);
}
