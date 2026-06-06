# win32 カスタムタイトルバー & タブ統合 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** win32 apprt の SysTabControl32 と標準タイトルバーを廃止し、タブを統合したカスタム描画タイトルバー(Windows Terminal 風・角丸トップ・テーマ追従色)に置き換える。

**Architecture:** `WM_NCCALCSIZE`/`WM_NCHITTEST` で標準キャプションを除去しクライアント領域上部 38px(DPI スケール)を自前描画。描画は新規 `TitleBar.zig`(HWND を持たない純モジュール)が担当し、図形は GDI+ flat C API(AA 角丸)、テキストは GDI `DrawTextW`(ClearType)、ダブルバッファ。色は毎描画時に `app.config` の background/foreground から導出(リロード自動追従)。

**Tech Stack:** Zig 0.15.2 / Win32 API (user32, gdi32, dwmapi, gdiplus) / 既存 sys.zig バインディングパターン

**Spec:** `docs/superpowers/specs/2026-06-06-win32-titlebar-tabs-design.md`

**検証についての注意(TDD の制約):** win32 コードは WSL では実行できないため、各タスクの検証は (1) `zig build -Dtarget=x86_64-windows-gnu` のクロスコンパイル、(2) 最終タスクでの Windows 実機チェックリスト で行う。純粋ロジック(色導出・レイアウト計算)は TitleBar.zig 内に `test` ブロックとして書く(Windows ターゲットのテストビルドでコンパイル検証される)。

---

### Task 1: sys.zig に Win32 バインディングを追加

**Files:**
- Modify: `src/apprt/win32/sys.zig`

- [ ] **Step 1: 定数・構造体・extern を追加**

`src/apprt/win32/sys.zig` の末尾(`WM_APP_NEW_WINDOW` の後)に追加:

```zig
// ---------------------------------------------------------------------------
// Custom frame (titlebar-integrated tabs) support
// ---------------------------------------------------------------------------

// Messages
pub const WM_ACTIVATE: UINT = 0x0006;
pub const WM_SETTEXT: UINT = 0x000C;
pub const WM_ERASEBKGND: UINT = 0x0014;
pub const WM_NCCALCSIZE: UINT = 0x0083;
pub const WM_NCHITTEST: UINT = 0x0084;
pub const WM_NCMOUSEMOVE: UINT = 0x00A0;
pub const WM_MOUSEMOVE: UINT = 0x0200;
pub const WM_LBUTTONDOWN: UINT = 0x0201;
pub const WM_LBUTTONUP: UINT = 0x0202;
pub const WM_MBUTTONUP: UINT = 0x0208;
pub const WM_MOUSELEAVE: UINT = 0x02A3;

// Hit-test results
pub const HTCLIENT: LRESULT = 1;
pub const HTCAPTION: LRESULT = 2;
pub const HTTOP: LRESULT = 12;

// System metrics (per-DPI)
pub const SM_CYCAPTION: c_int = 4;
pub const SM_CYFRAME: c_int = 33;
pub const SM_CXPADDEDBORDER: c_int = 92;
pub extern "user32" fn GetSystemMetricsForDpi(nIndex: c_int, dpi: UINT) callconv(.winapi) c_int;

// SetWindowPos flags / ShowWindow commands
pub const SWP_FRAMECHANGED: UINT = 0x0020;
pub const SW_MINIMIZE: c_int = 6;

// WM_NCCALCSIZE parameter block (wparam == 1)
pub const NCCALCSIZE_PARAMS = extern struct {
    rgrc: [3]RECT,
    lppos: ?*anyopaque,
};

// DWM
pub const MARGINS = extern struct {
    cxLeftWidth: c_int,
    cxRightWidth: c_int,
    cyTopHeight: c_int,
    cyBottomHeight: c_int,
};
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub extern "dwmapi" fn DwmExtendFrameIntoClientArea(hWnd: HWND, pMarInset: *const MARGINS) callconv(.winapi) i32;
pub extern "dwmapi" fn DwmSetWindowAttribute(hWnd: HWND, dwAttribute: DWORD, pvAttribute: *const anyopaque, cbAttribute: DWORD) callconv(.winapi) i32;

// Mouse tracking (hover leave detection)
pub const TRACKMOUSEEVENT = extern struct {
    cbSize: DWORD,
    dwFlags: DWORD,
    hwndTrack: HWND,
    dwHoverTime: DWORD,
};
pub const TME_LEAVE: DWORD = 0x0002;
pub extern "user32" fn TrackMouseEvent(lpEventTrack: *TRACKMOUSEEVENT) callconv(.winapi) BOOL;

// Misc helpers used by the custom titlebar
pub extern "user32" fn ScreenToClient(hWnd: HWND, lpPoint: *POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(hdc: HDC, lpchText: [*]const u16, cchText: c_int, lprc: *RECT, format: UINT) callconv(.winapi) c_int;
pub extern "user32" fn DrawIconEx(hdc: HDC, xLeft: i32, yTop: i32, hIcon: HICON, cxWidth: i32, cyWidth: i32, istepIfAniCur: UINT, hbrFlickerFreeDraw: HBRUSH, diFlags: UINT) callconv(.winapi) BOOL;
pub const DI_NORMAL: UINT = 0x0003;

// DrawTextW format flags
pub const DT_CENTER: UINT = 0x0001;
pub const DT_VCENTER: UINT = 0x0004;
pub const DT_SINGLELINE: UINT = 0x0020;
pub const DT_NOPREFIX: UINT = 0x0800;
pub const DT_END_ELLIPSIS: UINT = 0x8000;

// GDI (double buffering & text)
pub extern "gdi32" fn CreateCompatibleDC(hdc: HDC) callconv(.winapi) HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: c_int, cy: c_int) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: ?*anyopaque) callconv(.winapi) ?*anyopaque;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) BOOL;
pub extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
pub extern "gdi32" fn BitBlt(hdc: HDC, x: c_int, y: c_int, cx: c_int, cy: c_int, hdcSrc: HDC, x1: c_int, y1: c_int, rop: DWORD) callconv(.winapi) BOOL;
pub const SRCCOPY: DWORD = 0x00CC0020;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
pub const TRANSPARENT: c_int = 1;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
pub extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: ?*anyopaque) callconv(.winapi) c_int;
pub extern "gdi32" fn CreateFontW(cHeight: c_int, cWidth: c_int, cEscapement: c_int, cOrientation: c_int, cWeight: c_int, bItalic: DWORD, bUnderline: DWORD, bStrikeOut: DWORD, iCharSet: DWORD, iOutPrecision: DWORD, iClipPrecision: DWORD, iQuality: DWORD, iPitchAndFamily: DWORD, pszFaceName: [*:0]const u16) callconv(.winapi) ?*anyopaque;
```

注意: `CreateSolidBrush` / `FillRect` / `DeleteObject` / `CreateFontW` は Window.zig にファイルローカル extern が既にあるが、sys.zig に公開版を追加する(Task 5 で Window.zig ローカル版を整理)。重複 extern 宣言はシンボルが同じなら問題ない。

- [ ] **Step 2: クロスコンパイルで型チェック**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: エラーなし(終了コード 0、出力なし)

- [ ] **Step 3: コミット**

```bash
zig fmt src/apprt/win32/sys.zig
git add src/apprt/win32/sys.zig
git commit -m "win32: add bindings for custom frame titlebar (dwm, gdi, hit-test)"
```

---

### Task 2: TitleBar.zig — パレット導出とレイアウト/ヒットテスト(純粋ロジック)

**Files:**
- Create: `src/apprt/win32/TitleBar.zig`

- [ ] **Step 1: ファイル作成(状態・色・レイアウト・ヒットテスト + test ブロック)**

`src/apprt/win32/TitleBar.zig` を新規作成:

```zig
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
```

- [ ] **Step 2: クロスコンパイルで型チェック**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: エラーなし。
注: この時点では TitleBar.zig はどこからも import されていないため解析されない。次のコマンドで単体の構文/型を確認する:

Run: `zig ast-check src/apprt/win32/TitleBar.zig`
Expected: エラーなし

- [ ] **Step 3: コミット**

```bash
zig fmt src/apprt/win32/TitleBar.zig
git add src/apprt/win32/TitleBar.zig
git commit -m "win32: add TitleBar palette/layout/hit-test logic"
```

---

### Task 3: TitleBar.zig — GDI+/GDI 描画

**Files:**
- Modify: `src/apprt/win32/TitleBar.zig`(末尾に追記)

- [ ] **Step 1: GDI+ extern と描画コードを追加**

`src/apprt/win32/TitleBar.zig` の test ブロックの**前**に追加:

```zig
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
    self.text_font = sys.CreateFontW(
        -s(dpi, 12), // ~9pt UI text
        0, 0, 0, 400, 0, 0, 0, 1, 0, 0,
        5, // CLEARTYPE_QUALITY
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    self.glyph_font = sys.CreateFontW(
        -s(dpi, 10),
        0, 0, 0, 400, 0, 0, 0, 1, 0, 0,
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
        // Tab shapes need GDI+ (anti-aliased round tops).
        var graphics: *anyopaque = undefined;
        const has_g = GdipCreateFromHDC(mem_dc, &graphics) == 0;
        defer if (has_g) {
            _ = GdipDeleteGraphics(graphics);
        };
        if (has_g) _ = GdipSetSmoothingMode(graphics, smoothing_antialias);

        for (info.titles, 0..) |title, i| {
            const tr = layout.tabRect(i);
            const is_current = i == info.current;
            const is_hover = self.hover.eql(.{ .tab = i }) or self.hover.eql(.{ .tab_close = i });

            if (has_g) {
                if (is_current) {
                    fillRoundedTop(graphics, pal.active_tab.argb(), tr, layout.radius);
                } else if (is_hover) {
                    fillRoundedTop(graphics, pal.hover_tab.argb(), tr, layout.radius);
                }
            }

            // "N · title", ellipsized.
            var label_buf: [128]u8 = undefined;
            const label = std.fmt.bufPrint(&label_buf, "{d} · {s}", .{ i + 1, title }) catch title;

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
```

- [ ] **Step 2: 構文チェック**

Run: `zig ast-check src/apprt/win32/TitleBar.zig`
Expected: エラーなし

- [ ] **Step 3: コミット**

```bash
zig fmt src/apprt/win32/TitleBar.zig
git add src/apprt/win32/TitleBar.zig
git commit -m "win32: add TitleBar GDI+/GDI painting"
```

---

### Task 4: Window.zig — カスタムフレーム(NCCALCSIZE / NCHITTEST / DWM)

**Files:**
- Modify: `src/apprt/win32/Window.zig`

- [ ] **Step 1: import とフィールドを追加**

`Window.zig` 上部、`const App = @import("App.zig");`(L14)の後に:

```zig
const TitleBar = @import("TitleBar.zig");
```

フィールド群(L128-140 付近)の `tab_hwnd: ?HWND = null,` の下に追加(tab_hwnd の削除は Task 5):

```zig
titlebar: TitleBar = .{},
```

- [ ] **Step 2: フレームセットアップ関数を追加**

`createHwnd` の直後に追加:

```zig
/// Switch the window to a custom frame: the standard caption is
/// removed (WM_NCCALCSIZE) and we draw our own titlebar with
/// integrated tabs in the top strip of the client area. Quick
/// terminal windows keep their existing frameless style.
fn setupCustomFrame(self: *Window) void {
    if (self.quick_terminal) return;
    const hwnd = self.hwnd orelse return;

    // Hint dark mode so the system menu / transition chrome matches.
    const bg = self.app.config.background;
    const dark: i32 = if ((TitleBar.Rgb{ .r = bg.r, .g = bg.g, .b = bg.b }).isDark()) 1 else 0;
    _ = sys.DwmSetWindowAttribute(
        hwnd,
        sys.DWMWA_USE_IMMERSIVE_DARK_MODE,
        &dark,
        @sizeOf(i32),
    );

    // 1px top inset keeps the DWM drop shadow & Win11 rounded corners.
    const margins: sys.MARGINS = .{
        .cxLeftWidth = 0,
        .cxRightWidth = 0,
        .cyTopHeight = 1,
        .cyBottomHeight = 0,
    };
    _ = sys.DwmExtendFrameIntoClientArea(hwnd, &margins);

    // Force WM_NCCALCSIZE so the new frame takes effect.
    _ = sys.SetWindowPos(hwnd, null, 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0004 | sys.SWP_FRAMECHANGED);
}
```

`create()`(L149)内、`try self.createHwnd(opts.title);` の直後(errdefer の後)に呼び出しを追加:

```zig
    self.setupCustomFrame();
```

また `createHwnd` 内の `CreateWindowExW` のスタイル引数を変更(親の描画が子サーフェスを上書きしないように WS_CLIPCHILDREN を追加)。L227 の:

```zig
        if (self.quick_terminal) sys.WS_OVERLAPPEDWINDOW & ~sys.WS_CAPTION_BIT else sys.WS_OVERLAPPEDWINDOW,
```

を:

```zig
        (if (self.quick_terminal) sys.WS_OVERLAPPEDWINDOW & ~sys.WS_CAPTION_BIT else sys.WS_OVERLAPPEDWINDOW) | WS_CLIPCHILDREN,
```

に。ファイル上部の定数群(L25 付近)に追加:

```zig
const WS_CLIPCHILDREN: u32 = 0x02000000;
```

- [ ] **Step 3: titleBarHeight とフレームメトリクスのヘルパーを追加**

`tabClientHeight`(L601)の近くに追加(tabClientHeight の削除は Task 5):

```zig
/// Height of the custom titlebar strip in client pixels. Zero when
/// the strip is not shown (quick terminal & fullscreen keep their
/// existing chrome-less behavior).
fn titleBarHeight(self: *Window) i32 {
    if (self.quick_terminal or self.fullscreen.active) return 0;
    const hwnd = self.hwnd orelse return 0;
    return TitleBar.barHeight(sys.GetDpiForWindow(hwnd));
}

/// Height of the invisible top resize border (standard frame metric).
fn topResizeBorder(self: *Window) i32 {
    const hwnd = self.hwnd orelse return 8;
    const dpi = sys.GetDpiForWindow(hwnd);
    return sys.GetSystemMetricsForDpi(sys.SM_CYFRAME, dpi) +
        sys.GetSystemMetricsForDpi(sys.SM_CXPADDEDBORDER, dpi);
}

fn invalidateTitleBar(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var rect: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(hwnd, &rect) == 0) return;
    rect.bottom = self.titleBarHeight();
    _ = sys.InvalidateRect(hwnd, &rect, 0);
}

/// Palette derived fresh from the config every time so a config
/// reload is picked up automatically on the next paint.
fn themePalette(self: *Window) TitleBar.Palette {
    const bg = self.app.config.background;
    const fg = self.app.config.foreground;
    return TitleBar.Palette.derive(
        .{ .r = bg.r, .g = bg.g, .b = bg.b },
        .{ .r = fg.r, .g = fg.g, .b = fg.b },
    );
}
```

- [ ] **Step 4: handleTopLevelMessage に NCCALCSIZE / NCHITTEST / ACTIVATE / SETTEXT を追加**

`handleTopLevelMessage`(L1162)を以下のように変更。`_ = wparam;`(L1163)を**削除**し、switch に case を追加:

```zig
pub fn handleTopLevelMessage(self: *Window, msg: UINT, wparam: WPARAM, lparam: LPARAM) ?LRESULT {
    switch (msg) {
        sys.WM_NCCALCSIZE => {
            // Remove the standard caption: keep the client top edge at
            // the window top. Resize borders on the other 3 sides stay.
            if (wparam == 0 or self.quick_terminal or self.fullscreen.active) return null;
            const hwnd = self.hwnd orelse return null;
            const params: *sys.NCCALCSIZE_PARAMS = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const original_top = params.rgrc[0].top;
            _ = sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            params.rgrc[0].top = original_top;
            if (sys.IsZoomed(hwnd) != 0) {
                // When maximized the window hangs off-screen by the
                // frame size; push the client down so the strip is
                // fully visible.
                params.rgrc[0].top += self.topResizeBorder();
            }
            return 0;
        },
        sys.WM_NCHITTEST => {
            if (self.quick_terminal or self.fullscreen.active) return null;
            const hwnd = self.hwnd orelse return null;
            const def = sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            if (def != sys.HTCLIENT) return def;

            var pt: sys.POINT = .{
                .x = @as(i16, @truncate(lparam & 0xFFFF)),
                .y = @as(i16, @truncate((lparam >> 16) & 0xFFFF)),
            };
            _ = sys.ScreenToClient(hwnd, &pt);

            const maximized = sys.IsZoomed(hwnd) != 0;
            if (!maximized and pt.y < self.topResizeBorder()) return sys.HTTOP;

            const bar_h = self.titleBarHeight();
            if (pt.y < bar_h) {
                var rect: RECT = std.mem.zeroes(RECT);
                _ = sys.GetClientRect(hwnd, &rect);
                const layout = TitleBar.Layout.compute(
                    sys.GetDpiForWindow(hwnd),
                    rect.right - rect.left,
                    @max(self.tabs.items.len, 1),
                );
                return switch (layout.hitTest(pt.x, pt.y, maximized)) {
                    .caption => sys.HTCAPTION,
                    // Tabs and buttons are handled by our own client
                    // mouse handlers.
                    else => sys.HTCLIENT,
                };
            }
            return sys.HTCLIENT;
        },
        sys.WM_ACTIVATE => {
            self.titlebar.window_active = (wparam & 0xFFFF) != 0;
            self.invalidateTitleBar();
            return null;
        },
        sys.WM_SETTEXT => {
            // Window title is drawn in the strip when a single tab is
            // open; repaint after the default proc stores the text.
            self.invalidateTitleBar();
            return null;
        },
        sys.WM_ERASEBKGND => return 1,
        else => {},
    }
    return null;
}
```

(既存の `WM_NOTIFY` case はこの時点ではまだ残す — Task 5 で削除。)

- [ ] **Step 5: クロスコンパイル**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: エラーなし

- [ ] **Step 6: コミット**

```bash
zig fmt src/apprt/win32/Window.zig
git add src/apprt/win32/Window.zig
git commit -m "win32: custom window frame (remove native caption, dwm dark hint)"
```

---

### Task 5: Window.zig — SysTabControl32 廃止と TitleBar 配線

**Files:**
- Modify: `src/apprt/win32/Window.zig`

- [ ] **Step 1: SysTabControl32 関連コードを削除**

以下を削除する:

1. 定数(L25-49 のうち): `WS_TABSTOP`, `TCS_FIXEDWIDTH`, `WM_NOTIFY`, `WM_SETFONT`, `TCM_FIRST` から `TCN_SELCHANGE` までの全 TCM/TCN 定数, `TCIF_TEXT`, `ICC_TAB_CLASSES`, `TAB_HEIGHT`
2. 構造体: `NMHDR`(L55-59), `INITCOMMONCONTROLSEX`(L61-64), `TCITEMW`(L66-74)
3. extern: `InitCommonControlsEx`(L76), `CreateFontW`(L77)
4. グローバル: `var ui_font: ?*anyopaque = null;`(L85)
5. フィールド: `tab_hwnd: ?HWND = null,`(L130)
6. 関数全体: `createTabControl`(L242-283), `updateTabVisibility`(L595-599), `tabClientHeight`(L601-603), `rebuildTabControl`(L624-632), `updateTabMetrics`(L634-649), `insertTabControlItem`(L651-660), `updateTabControlTitle`(L662-671)
7. `create()` 内の `try self.createTabControl();`(L164)
8. `deinit()` 内の tab_hwnd 破棄ブロック(L188-191)
9. `handleTopLevelMessage` 内の `WM_NOTIFY` case(L1165-1173)

注意: `WM_PAINT`, `WM_LBUTTONDOWN/UP`, `WM_MOUSEMOVE`, `WM_CAPTURECHANGED`, `WM_SETCURSOR`, `SW_HIDE` の定数と `CreateSolidBrush`/`DeleteObject`/`FillRect`/`SetCapture`/`ReleaseCapture`/`SetCursor` の extern はディバイダー処理が使うので**残す**。

- [ ] **Step 2: 旧 API 呼び出し箇所を置換**

パターン: `TCM_*` の `SendMessageW` / `rebuildTabControl` / `updateTabVisibility` 呼び出しをすべて `self.invalidateTitleBar()` に置換(連続する場合は 1 回に統合)。対象:

- `insertTab`(L490-539): L528-529 の `self.rebuildTabControl(); self.updateTabVisibility();` → `self.invalidateTitleBar();`。L535 の `_ = sys.SendMessageW(self.tab_hwnd.?, TCM_SETCURSEL, ...)` 行を削除
- `setActiveTabTitle`(L588-593): `self.updateTabControlTitle(self.current_tab);` → `self.invalidateTitleBar();`
- `activateTab`(L673-693): L676 と L690 の `TCM_SETCURSEL` SendMessage 行を削除し、関数末尾(`relayout()` の前)に `self.invalidateTitleBar();` を追加
- `closeTabAt`(L707-746): L720 の `TCM_DELETEITEM` 行を削除。L743-744 の `self.updateTabVisibility(); self.rebuildTabControl();` → `self.invalidateTitleBar();`
- `closeEmptyTabAt`(L748-782): L779-780 同様に置換
- `moveTab`(L806-820): L817 の `self.rebuildTabControl();` → `self.invalidateTitleBar();`

- [ ] **Step 3: レイアウト関数を新メトリクスに切替**

- `relayout`(L919-937): `self.updateTabMetrics();` 行を削除。`const tab_h = self.tabClientHeight();` → `const tab_h = self.titleBarHeight();`。`if (self.tab_hwnd) |tab_hwnd| { ... SetWindowPos ... }` ブロックを削除。関数末尾に `self.invalidateTitleBar();` を追加
- `gotoSplit`(L1021 内 L1031, L1033): `self.tabClientHeight()` → `self.titleBarHeight()`(2 箇所)
- `applyConfiguredWindowSize`(L867-883): `self.tabClientHeight()` → `self.titleBarHeight()`。`AdjustWindowRectEx` の後に標準キャプション分を差し引く:

```zig
    var rect: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    _ = sys.AdjustWindowRectEx(&rect, sys.WS_OVERLAPPEDWINDOW, 0, 0);
    // The custom frame has no caption; AdjustWindowRectEx includes one.
    var height = rect.bottom - rect.top;
    if (!self.quick_terminal) {
        const dpi = sys.GetDpiForWindow(hwnd);
        height -= sys.GetSystemMetricsForDpi(sys.SM_CYCAPTION, dpi);
    }
    _ = sys.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, height, 0x0002 | 0x0004);
```

- `deinit`(L181-196): `self.titlebar.deinit();` を `self.destroyDividers();` の直後に追加

- [ ] **Step 4: WM_PAINT とマウスハンドラを handleTopLevelMessage に追加**

Task 4 で追加した switch に case を追記:

```zig
        sys.WM_PAINT => {
            const hwnd = self.hwnd orelse return null;
            var ps: sys.PAINTSTRUCT = std.mem.zeroes(sys.PAINTSTRUCT);
            const hdc = sys.BeginPaint(hwnd, &ps);
            defer _ = sys.EndPaint(hwnd, &ps);

            var rect: RECT = std.mem.zeroes(RECT);
            _ = sys.GetClientRect(hwnd, &rect);
            const width = rect.right - rect.left;
            const bar_h = self.titleBarHeight();

            // Anything below the strip belongs to child windows;
            // clear exposed leftovers with the terminal background.
            if (ps.rcPaint.bottom > bar_h) {
                const bg = self.app.config.background;
                const brush = sys.CreateSolidBrush(
                    (TitleBar.Rgb{ .r = bg.r, .g = bg.g, .b = bg.b }).colorref(),
                ) orelse return 0;
                defer _ = sys.DeleteObject(brush);
                var below = ps.rcPaint;
                below.top = @max(below.top, bar_h);
                _ = sys.FillRect(hdc, &below, brush);
            }

            if (bar_h > 0 and width > 0) {
                // Collect tab titles (UTF-8).
                var titles_buf: [64][:0]const u8 = undefined;
                const count = @min(self.tabs.items.len, titles_buf.len);
                for (self.tabs.items[0..count], 0..) |tab, i| titles_buf[i] = tab.title;
                // Teardown can paint with zero tabs; keep titles valid.
                if (count == 0) titles_buf[0] = "";

                // Window title (UTF-16) for the single-tab state.
                var title_buf: [256]u16 = undefined;
                const title_len = sys.GetWindowTextW(hwnd, &title_buf, @intCast(title_buf.len));

                self.titlebar.paint(.{
                    .dc = hdc,
                    .width = width,
                    .dpi = sys.GetDpiForWindow(hwnd),
                    .palette = self.themePalette(),
                    .titles = titles_buf[0..@max(count, 1)],
                    .current = self.current_tab,
                    .single_title = title_buf[0..@intCast(@max(title_len, 0))],
                    .maximized = sys.IsZoomed(hwnd) != 0,
                    .icon = sys.LoadIconW(sys.GetModuleHandleW(null), @ptrFromInt(1)),
                });
            }
            return 0;
        },
        sys.WM_MOUSEMOVE => {
            const hwnd = self.hwnd orelse return null;
            const elem = self.titleBarHit(lparam);
            if (!elem.eql(self.titlebar.hover)) {
                self.titlebar.hover = elem;
                self.invalidateTitleBar();
            }
            if (!self.titlebar.tracking_mouse) {
                var tme: sys.TRACKMOUSEEVENT = .{
                    .cbSize = @sizeOf(sys.TRACKMOUSEEVENT),
                    .dwFlags = sys.TME_LEAVE,
                    .hwndTrack = hwnd,
                    .dwHoverTime = 0,
                };
                _ = sys.TrackMouseEvent(&tme);
                self.titlebar.tracking_mouse = true;
            }
            return 0;
        },
        sys.WM_MOUSELEAVE, sys.WM_NCMOUSEMOVE => {
            self.titlebar.tracking_mouse = false;
            if (!self.titlebar.hover.eql(.none)) {
                self.titlebar.hover = .none;
                self.invalidateTitleBar();
            }
            return null;
        },
        sys.WM_LBUTTONDOWN => {
            const elem = self.titleBarHit(lparam);
            switch (elem) {
                .none, .caption => {},
                .tab => |i| self.activateTab(i) catch {},
                // Buttons act on release (standard Windows behavior).
                // Note: variants with differing payload types cannot be
                // grouped in one prong, hence the else.
                else => {
                    self.titlebar.pressed = elem;
                    _ = SetCapture(self.hwnd.?);
                    self.invalidateTitleBar();
                },
            }
            return 0;
        },
        sys.WM_LBUTTONUP => {
            const pressed = self.titlebar.pressed;
            if (pressed.eql(.none)) return 0;
            self.titlebar.pressed = .none;
            _ = ReleaseCapture();
            const elem = self.titleBarHit(lparam);
            if (elem.eql(pressed)) {
                const hwnd = self.hwnd.?;
                switch (pressed) {
                    .tab_close => |i| self.closeTabAt(i),
                    .new_tab => self.newTab(.none) catch {},
                    .minimize => _ = sys.ShowWindow(hwnd, sys.SW_MINIMIZE),
                    .maximize => _ = sys.ShowWindow(
                        hwnd,
                        if (sys.IsZoomed(hwnd) != 0) sys.SW_RESTORE else sys.SW_MAXIMIZE,
                    ),
                    .close => _ = sys.PostMessageW(hwnd, sys.WM_CLOSE, 0, 0),
                    else => {},
                }
            }
            self.invalidateTitleBar();
            return 0;
        },
        sys.WM_MBUTTONUP => {
            switch (self.titleBarHit(lparam)) {
                .tab, .tab_close => |i| self.closeTabAt(i),
                else => {},
            }
            return 0;
        },
```

注意: `.tab, .tab_close => |i|` は両 variant とも payload が `usize` なのでまとめてキャプチャできる。

ヘルパーを `handleTopLevelMessage` の近くに追加:

```zig
/// Map a client-coordinate mouse lparam to a titlebar element.
fn titleBarHit(self: *Window, lparam: LPARAM) TitleBar.Element {
    const hwnd = self.hwnd orelse return .none;
    const bar_h = self.titleBarHeight();
    if (bar_h == 0) return .none;
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    var rect: RECT = std.mem.zeroes(RECT);
    _ = sys.GetClientRect(hwnd, &rect);
    const layout = TitleBar.Layout.compute(
        sys.GetDpiForWindow(hwnd),
        rect.right - rect.left,
        @max(self.tabs.items.len, 1),
    );
    return layout.hitTest(x, y, sys.IsZoomed(hwnd) != 0);
}
```

- [ ] **Step 5: クロスコンパイル(全削除の取り残し検出)**

Run: `zig build -Dtarget=x86_64-windows-gnu`
Expected: エラーなし。`tab_hwnd` / `TCM_` / `rebuildTabControl` 等への参照が残っているとここでコンパイルエラーになる。

Run: `grep -n "tab_hwnd\|TCM_\|TCN_\|SysTabControl\|rebuildTabControl\|updateTabVisibility\|updateTabMetrics\|tabClientHeight\|TAB_HEIGHT" src/apprt/win32/Window.zig`
Expected: マッチなし

- [ ] **Step 6: コミット**

```bash
zig fmt src/apprt/win32/Window.zig
git add src/apprt/win32/Window.zig
git commit -m "win32: replace SysTabControl32 with custom titlebar tabs"
```

---

### Task 6: 最終検証(フォーマット・クロスビルド・実機チェックリスト)

**Files:** なし(検証のみ)

- [ ] **Step 1: フォーマットと最終クロスコンパイル**

```bash
zig fmt src/apprt/win32/
zig build -Dtarget=x86_64-windows-gnu
```
Expected: 差分なし・ビルド成功

- [ ] **Step 2: Linux ネイティブの回帰確認(共有コードに影響なしの確認)**

Run: `git diff --stat main...HEAD -- src/ ':!src/apprt/win32'`
Expected: win32 ディレクトリと sys.zig 以外への変更がないこと(共有コードを触っていないので GTK/macOS への回帰なし)

- [ ] **Step 3: Windows 実機検証(ユーザー実施)**

`./sync-to-windows.sh` で同期し、Windows 側でビルド・起動して以下を確認:

| # | 確認項目 | 期待 |
|---|---|---|
| 1 | 起動直後(1 タブ) | ダークなタイトルバーにウィンドウタイトル文字のみ。タブ形状なし |
| 2 | Ctrl+Shift+T で 2 タブ目 | タブが 2 つ出現。アクティブタブは角丸トップでターミナル背景と同色 |
| 3 | タブホバー | 薄くハイライト + ✕ 出現。✕ クリックでそのタブが閉じる |
| 4 | ミドルクリック | タブが閉じる |
| 5 | + ボタン | 新規タブが開く |
| 6 | 空き領域ドラッグ | ウィンドウが移動する。ダブルクリックで最大化/復元 |
| 7 | 上端 8px | リサイズカーソルになり上方向リサイズできる |
| 8 | ─ □ ✕ ボタン | 最小化/最大化(復元)/閉じる。✕ ホバーは赤 |
| 9 | 最大化 | タブバーが画面外に切れない。タブ上余白クリックがタブに効く |
| 10 | Win+矢印スナップ | 正常にスナップする |
| 11 | 非アクティブ化 | 文字が減衰して描画される |
| 12 | フルスクリーン(toggle_fullscreen) | バーごと消え、復帰で戻る |
| 13 | DPI 150% モニタ | バー高さ・文字が適切にスケール |
| 14 | ライトテーマ設定(background=#FFFFFF 等) | バーが破綻しない(明るいグレー系になる) |

- [ ] **Step 4: 問題なければ完了。スクリーンショットでビフォーアフター確認**

---

## Self-Review 済み事項

- スペックの全要件にタスクが対応(フレーム=T4、描画=T2/T3、配線=T5、検証=T6)
- スコープ外(ドラッグ並べ替え/スナップレイアウト/ツールチップ)はコード追加なし
- 型整合: `TitleBar.Element`/`Layout`/`Palette`/`PaintInfo` の定義(T2/T3)と使用(T4/T5)で署名一致を確認済み
- 既知の妥協: DWM ダークモードヒントはウィンドウ作成時のみ(テーマリロードで明暗が反転した場合はバー色は追従するが OS 側ヒントは再起動まで残る)
