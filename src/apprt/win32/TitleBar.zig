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

// ---------------------------------------------------------------------------
// Painting
// ---------------------------------------------------------------------------

// GDI+ flat C API (anti-aliased shapes). COM-free; just GdiplusStartup
// once, then create a Graphics per paint from the target HDC.
const GdiplusStartupInput = extern struct {
    GdiplusVersion: u32 = 1,
    DebugEventCallback: ?*anyopaque = null,
    SuppressBackgroundThread: i32 = 0,
    SuppressExternalCodecs: i32 = 0,
};
extern "gdiplus" fn GdiplusStartup(token: *usize, input: *const GdiplusStartupInput, output: ?*anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipCreateFromHDC(hdc: sys.HDC, graphics: **anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipDeleteGraphics(graphics: *anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipSetSmoothingMode(graphics: *anyopaque, mode: c_int) callconv(.winapi) c_int;
extern "gdiplus" fn GdipCreateSolidFill(color: u32, brush: **anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipDeleteBrush(brush: *anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipCreatePath(fill_mode: c_int, path: **anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipDeletePath(path: *anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipAddPathArc(path: *anyopaque, x: f32, y: f32, w: f32, h: f32, start: f32, sweep: f32) callconv(.winapi) c_int;
extern "gdiplus" fn GdipAddPathLine(path: *anyopaque, x1: f32, y1: f32, x2: f32, y2: f32) callconv(.winapi) c_int;
extern "gdiplus" fn GdipClosePathFigure(path: *anyopaque) callconv(.winapi) c_int;
extern "gdiplus" fn GdipFillPath(graphics: *anyopaque, brush: *anyopaque, path: *anyopaque) callconv(.winapi) c_int;

const smoothing_antialias: c_int = 4;

// GdiplusShutdown is intentionally never called; GDI+ is a process-lifetime
// resource and there is no clean shutdown point in a GUI application.
var gdiplus_token: usize = 0;

fn ensureGdiplus() void {
    if (gdiplus_token != 0) return;
    const input: GdiplusStartupInput = .{};
    _ = GdiplusStartup(&gdiplus_token, &input, null);
}

/// Fill a rectangle whose top two corners are rounded (the classic
/// "tab" shape); bottom edge is square so the active tab merges into
/// the terminal area below.
fn fillRoundedTop(g: *anyopaque, color: u32, r: RECT, radius: i32) void {
    var brush: *anyopaque = undefined;
    if (GdipCreateSolidFill(color, &brush) != 0) return;
    defer _ = GdipDeleteBrush(brush);

    var path: *anyopaque = undefined;
    if (GdipCreatePath(0, &path) != 0) return;
    defer _ = GdipDeletePath(path);

    const x: f32 = @floatFromInt(r.left);
    const y: f32 = @floatFromInt(r.top);
    const w: f32 = @floatFromInt(r.right - r.left);
    const h: f32 = @floatFromInt(r.bottom - r.top);
    const d: f32 = @floatFromInt(radius * 2);

    _ = GdipAddPathArc(path, x, y, d, d, 180, 90); // top-left corner
    _ = GdipAddPathArc(path, x + w - d, y, d, d, 270, 90); // top-right corner
    _ = GdipAddPathLine(path, x + w, y + d / 2, x + w, y + h);
    _ = GdipAddPathLine(path, x + w, y + h, x, y + h);
    _ = GdipClosePathFigure(path);
    _ = GdipFillPath(g, brush, path);
}

fn ensureFonts(self: *TitleBar, dpi: u32) void {
    if (self.fonts_dpi == dpi and self.text_font != null) return;
    if (self.text_font) |f| _ = sys.DeleteObject(f);
    if (self.glyph_font) |f| _ = sys.DeleteObject(f);
    // If CreateFontW fails, the field stays null and SelectObject with null
    // is a no-op — the code degrades gracefully to the default GDI font.
    self.text_font = sys.CreateFontW(
        -s(dpi, 12), // ~9pt UI text
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        1,
        0,
        0,
        5, // CLEARTYPE_QUALITY
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    self.glyph_font = sys.CreateFontW(
        -s(dpi, 10),
        0,
        0,
        0,
        400,
        0,
        0,
        0,
        1,
        0,
        0,
        5, // CLEARTYPE_QUALITY
        0,
        // Caption glyphs (minimize/maximize/restore/close) come from
        // the system icon font, same as native Windows titlebars.
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe MDL2 Assets"),
    );
    self.fonts_dpi = dpi;
}

fn drawTextUtf8(dc: sys.HDC, text: []const u8, rect: RECT, color: u32, flags: sys.UINT) void {
    var wbuf: [256]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
    if (wlen == 0) return;
    _ = sys.SetTextColor(dc, color);
    var r = rect;
    _ = sys.DrawTextW(dc, wbuf[0..wlen].ptr, @intCast(wlen), &r, flags);
}

fn drawTextUtf16(dc: sys.HDC, text: []const u16, rect: RECT, color: u32, flags: sys.UINT) void {
    if (text.len == 0) return;
    _ = sys.SetTextColor(dc, color);
    var r = rect;
    _ = sys.DrawTextW(dc, text.ptr, @intCast(text.len), &r, flags);
}

fn fillRect(dc: sys.HDC, rect: RECT, color: u32) void {
    const brush = sys.CreateSolidBrush(color) orelse return;
    defer _ = sys.DeleteObject(brush);
    _ = sys.FillRect(dc, &rect, brush);
}

// Segoe MDL2 Assets glyph codepoints (native caption glyphs).
const glyph_minimize = std.unicode.utf8ToUtf16LeStringLiteral("\u{E921}");
const glyph_maximize = std.unicode.utf8ToUtf16LeStringLiteral("\u{E922}");
const glyph_restore = std.unicode.utf8ToUtf16LeStringLiteral("\u{E923}");
const glyph_close = std.unicode.utf8ToUtf16LeStringLiteral("\u{E8BB}");

pub const PaintInfo = struct {
    dc: sys.HDC,
    width: i32,
    dpi: u32,
    palette: Palette,
    /// UTF-8 tab titles. len >= 1.
    titles: []const [:0]const u8,
    current: usize,
    /// Window title (UTF-16) shown when only one tab exists.
    single_title: []const u16,
    maximized: bool,
    icon: sys.HICON,
};

pub fn paint(self: *TitleBar, info: PaintInfo) void {
    ensureGdiplus();
    self.ensureFonts(info.dpi);

    const layout = Layout.compute(info.dpi, info.width, info.titles.len);
    const h = layout.height;

    // Double buffer: render everything into a memory DC, then blit.
    const mem_dc = sys.CreateCompatibleDC(info.dc) orelse return;
    defer _ = sys.DeleteDC(mem_dc);
    const bitmap = sys.CreateCompatibleBitmap(info.dc, info.width, h) orelse return;
    defer _ = sys.DeleteObject(bitmap);
    const old_bitmap = sys.SelectObject(mem_dc, bitmap);
    defer _ = sys.SelectObject(mem_dc, old_bitmap);

    _ = sys.SetBkMode(mem_dc, sys.TRANSPARENT);

    const pal = &info.palette;
    fillRect(mem_dc, .{ .left = 0, .top = 0, .right = info.width, .bottom = h }, pal.bar_bg.colorref());

    // App icon on the left.
    if (info.icon != null) {
        const size = s(info.dpi, 16);
        _ = sys.DrawIconEx(
            mem_dc,
            @divTrunc(layout.icon_w - size, 2),
            @divTrunc(h - size, 2),
            info.icon,
            size,
            size,
            0,
            null,
            sys.DI_NORMAL,
        );
    }

    const text_flags = sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_NOPREFIX | sys.DT_END_ELLIPSIS;
    const old_font = sys.SelectObject(mem_dc, self.text_font);
    defer _ = sys.SelectObject(mem_dc, old_font);

    if (!layout.show_tabs) {
        // Single tab: plain window title, no tab shapes.
        const r: RECT = .{
            .left = layout.icon_w + s(info.dpi, 4),
            .top = 0,
            .right = layout.buttons_x - s(info.dpi, 8),
            .bottom = h,
        };
        drawTextUtf16(
            mem_dc,
            info.single_title,
            r,
            pal.textColor(true, self.window_active).colorref(),
            text_flags,
        );
    } else {
        // Pass 1: tab shapes via GDI+. The Graphics object may batch
        // its drawing, so it must be fully deleted (committing the
        // batch to the DC) before any GDI text below — otherwise the
        // fills can paint over the labels.
        gdip: {
            var graphics: *anyopaque = undefined;
            if (GdipCreateFromHDC(mem_dc, &graphics) != 0) break :gdip;
            defer _ = GdipDeleteGraphics(graphics);
            _ = GdipSetSmoothingMode(graphics, smoothing_antialias);
            for (info.titles, 0..) |_, i| {
                const tr = layout.tabRect(i);
                const is_current = i == info.current;
                const is_hover = self.hover.eql(.{ .tab = i }) or self.hover.eql(.{ .tab_close = i });
                if (is_current) {
                    fillRoundedTop(graphics, pal.active_tab.argb(), tr, layout.radius);
                } else if (is_hover) {
                    fillRoundedTop(graphics, pal.hover_tab.argb(), tr, layout.radius);
                }
            }
        }

        // Pass 2: text/glyphs via GDI (ClearType). The GDI+ Graphics
        // object has already been deleted above, committing all shapes.
        for (info.titles, 0..) |title, i| {
            const tr = layout.tabRect(i);
            const is_current = i == info.current;
            const is_hover = self.hover.eql(.{ .tab = i }) or self.hover.eql(.{ .tab_close = i });

            // "N · title", ellipsized. On overflow, truncate the title
            // to fit, backing off to a clean UTF-8 codepoint boundary.
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d} · {s}", .{ i + 1, title }) catch blk: {
                // Title too long for the buffer: truncate it. DrawTextW
                // adds the visual ellipsis, this only bounds the bytes.
                const prefix = std.fmt.bufPrint(&label_buf, "{d} · ", .{i + 1}) catch break :blk title[0..@min(title.len, label_buf.len)];
                const room = label_buf.len - prefix.len;
                var cut = @min(title.len, room);
                // Back off to a clean UTF-8 codepoint boundary so we
                // don't hand a truncated multi-byte sequence to DrawTextW.
                while (cut > 0 and (title[cut] & 0xC0) == 0x80) cut -= 1;
                @memcpy(label_buf[prefix.len..][0..cut], title[0..cut]);
                break :blk label_buf[0 .. prefix.len + cut];
            };

            const close_r = layout.tabCloseRect(i);
            const show_close = is_current or is_hover;
            const text_r: RECT = .{
                .left = tr.left + s(info.dpi, 12),
                .top = tr.top,
                .right = if (show_close) close_r.left - s(info.dpi, 4) else tr.right - s(info.dpi, 12),
                .bottom = tr.bottom,
            };
            drawTextUtf8(
                mem_dc,
                label,
                text_r,
                pal.textColor(is_current, self.window_active).colorref(),
                text_flags,
            );

            if (show_close) {
                const hover_close = self.hover.eql(.{ .tab_close = i });
                _ = sys.SelectObject(mem_dc, self.glyph_font);
                drawTextUtf16(
                    mem_dc,
                    glyph_close,
                    close_r,
                    pal.textColor(hover_close, self.window_active).colorref(),
                    sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_CENTER | sys.DT_NOPREFIX,
                );
                _ = sys.SelectObject(mem_dc, self.text_font);
            }
        }

        // "+" (new tab) button.
        const plus_r: RECT = .{
            .left = layout.plus_x,
            .top = layout.tab_top,
            .right = layout.plus_x + layout.plus_w,
            .bottom = h,
        };
        if (self.hover.eql(.new_tab)) fillRect(mem_dc, plus_r, pal.btn_hover.colorref());
        drawTextUtf8(
            mem_dc,
            "+",
            plus_r,
            pal.textColor(false, self.window_active).colorref(),
            sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_CENTER | sys.DT_NOPREFIX,
        );
    }

    // Caption buttons (always shown, full bar height).
    _ = sys.SelectObject(mem_dc, self.glyph_font);
    const buttons = [3]struct { elem: Element, glyph: []const u16 }{
        .{ .elem = .minimize, .glyph = glyph_minimize },
        .{ .elem = .maximize, .glyph = if (info.maximized) glyph_restore else glyph_maximize },
        .{ .elem = .close, .glyph = glyph_close },
    };
    for (buttons, 0..) |btn, i| {
        const idx: i32 = @intCast(i);
        const br: RECT = .{
            .left = layout.buttons_x + idx * layout.btn_w,
            .top = 0,
            .right = layout.buttons_x + (idx + 1) * layout.btn_w,
            .bottom = h,
        };
        const hovered = self.hover.eql(btn.elem);
        var glyph_color = pal.textColor(true, self.window_active);
        if (hovered) {
            const bg = if (btn.elem.eql(.close)) pal.close_hover else pal.btn_hover;
            fillRect(mem_dc, br, bg.colorref());
            if (btn.elem.eql(.close)) glyph_color = .{ .r = 255, .g = 255, .b = 255 };
        }
        drawTextUtf16(
            mem_dc,
            btn.glyph,
            br,
            glyph_color.colorref(),
            sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_CENTER | sys.DT_NOPREFIX,
        );
    }

    _ = sys.BitBlt(info.dc, 0, 0, info.width, h, mem_dc, 0, 0, sys.SRCCOPY);
}

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
