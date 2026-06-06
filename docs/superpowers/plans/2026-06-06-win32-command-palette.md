# win32 コマンドパレット リデザイン 実装プラン

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ctrl+Shift+P のコマンドパレットを、テーマ追従色・角丸ピル選択・キーバインド表示・ファジー検索を備えたモダンデザイン(PowerToys Run 風)に刷新する。

**Architecture:** ネイティブ EDIT(IME 保全)+ オーナードロー LISTBOX(`LBS_OWNERDRAWFIXED` + `WM_DRAWITEM`)。色は `TitleBar.Palette` を共有・拡張し、角丸は TitleBar.zig に追加する `fillRoundedRect`(GDI+)で描画。ポップアップ角丸/枠色は DWM API。ファジーマッチとキーバインド整形は pure 関数として実装しユニットテスト付き。

**Tech Stack:** Zig 0.15.2 / Win32 (user32, gdi32, dwmapi, uxtheme, gdiplus) / 既存 TitleBar.zig の Rgb/Palette/GDI+ 基盤

**Spec:** `docs/superpowers/specs/2026-06-06-win32-command-palette-design.md`

**検証の制約:** win32 コードは WSL で実行不可。各タスクのゲートは (1) `zig ast-check`(構文)、(2) `zig build -Dtarget=x86_64-windows-gnu`(型)、(3) 最終タスクの Windows 実機チェックリスト。pure 関数(fuzzyMatch / formatTrigger)は `test` ブロック付きで書く。

**注意:** `zig fmt` は必ず**変更したファイル名を明示して**実行する(`zig fmt src/apprt/win32/` はディレクトリ内の無関係な既存コードまで整形してしまうため禁止)。

---

### Task 1: 共有基盤 — sys.zig バインディングと TitleBar.Palette 拡張

**Files:**
- Modify: `src/apprt/win32/sys.zig`(末尾に追記)
- Modify: `src/apprt/win32/TitleBar.zig`(Palette 拡張 + fillRoundedRect 追加)

- [ ] **Step 1: sys.zig に追記**

`src/apprt/win32/sys.zig` の末尾に追加:

```zig
// ---------------------------------------------------------------------------
// Command palette support
// ---------------------------------------------------------------------------

// Win11 window corner rounding & border color (no-ops on Win10).
pub const DWMWA_WINDOW_CORNER_PREFERENCE: DWORD = 33;
pub const DWMWA_BORDER_COLOR: DWORD = 34;
pub const DWMWCP_ROUND: i32 = 2;

// Text measurement
pub const SIZE = extern struct { cx: i32, cy: i32 };
pub extern "gdi32" fn GetTextExtentPoint32W(hdc: HDC, lpString: [*]const u16, c: c_int, psizl: *SIZE) callconv(.winapi) BOOL;

// Visual styles (dark scrollbars via the undocumented-but-stable
// "DarkMode_Explorer" subclass; failure is harmless).
pub extern "uxtheme" fn SetWindowTheme(hwnd: HWND, pszSubAppName: ?[*:0]const u16, pszSubIdList: ?[*:0]const u16) callconv(.winapi) i32;
```

- [ ] **Step 2: TitleBar.Palette に 3 フィールド追加**

`src/apprt/win32/TitleBar.zig` の `Palette` 構造体のフィールド末尾(`close_hover: Rgb,` の後)に追加:

```zig
    /// Selected-row fill for list-style popups (command palette).
    selection: Rgb,
    /// Raised surface色 (e.g. keycap chips) on top of bar_bg.
    surface: Rgb,
    /// Subtle outline/separator color.
    outline: Rgb,
```

`Palette.derive` の return 構造体に追加(`.close_hover = ...` の後):

```zig
            .selection = lighten(bar, 14),
            .surface = lighten(bar, 6),
            .outline = lighten(bar, 22),
```

`test "palette derives theme-relative colors"` に検証を 2 行追加(既存 expect 群の後):

```zig
    // popup-selection colors sit above the bar background
    try std.testing.expect(p.selection.r > p.bar_bg.r);
    try std.testing.expect(p.outline.r > p.surface.r);
```

- [ ] **Step 3: TitleBar.zig に fillRoundedRect を追加**

`fillRoundedTop` 関数の直後に追加:

```zig
/// Fill a fully-rounded rectangle with GDI+ (anti-aliased). Creates a
/// transient Graphics on the DC and deletes it before returning, which
/// commits the GDI+ batch — callers may freely mix subsequent GDI
/// drawing on the same DC (same rule as the titlebar two-pass paint).
pub fn fillRoundedRect(dc: sys.HDC, color: u32, r: RECT, radius: i32) void {
    ensureGdiplus();
    var graphics: *anyopaque = undefined;
    if (GdipCreateFromHDC(dc, &graphics) != 0) return;
    defer _ = GdipDeleteGraphics(graphics);
    _ = GdipSetSmoothingMode(graphics, smoothing_antialias);

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

    _ = GdipAddPathArc(path, x, y, d, d, 180, 90); // top-left
    _ = GdipAddPathArc(path, x + w - d, y, d, d, 270, 90); // top-right
    _ = GdipAddPathArc(path, x + w - d, y + h - d, d, d, 0, 90); // bottom-right
    _ = GdipAddPathArc(path, x, y + h - d, d, d, 90, 90); // bottom-left
    _ = GdipClosePathFigure(path);
    _ = GdipFillPath(graphics, brush, path);
}
```

- [ ] **Step 4: 検証**

```bash
zig ast-check src/apprt/win32/TitleBar.zig
zig build -Dtarget=x86_64-windows-gnu
```
Expected: 両方エラーなし

- [ ] **Step 5: コミット**

```bash
zig fmt src/apprt/win32/sys.zig src/apprt/win32/TitleBar.zig
git add src/apprt/win32/sys.zig src/apprt/win32/TitleBar.zig
git commit -m "win32: extend palette and add rounded-rect fill for command palette"
```

---

### Task 2: pure ロジック — ファジーマッチとトリガー整形(テスト付き)

**Files:**
- Modify: `src/apprt/win32/CommandPalette.zig`(関数追加のみ。既存動作は変更しない)

- [ ] **Step 1: import 追加**

`const Window = @import("Window.zig");`(L12)の後に:

```zig
const TitleBar = @import("TitleBar.zig");
```

- [ ] **Step 2: Match 型と fuzzyMatch をファイル末尾に追加**

```zig
// ---------------------------------------------------------------------------
// Fuzzy matching
// ---------------------------------------------------------------------------

/// A filtered command entry: which command, how well it matched, and
/// which title bytes matched (for highlight rendering).
const Match = struct {
    cmd_idx: usize,
    score: i32,
    /// Bit i set = title byte i matched (first 64 bytes only). Empty
    /// when the match was against the action name, not the title.
    positions: std.StaticBitSet(64),
};

/// Result of a fuzzy match against a single string.
const FuzzyResult = struct {
    score: i32,
    positions: std.StaticBitSet(64),
};

/// Case-insensitive subsequence match of `query` in `text`: every query
/// byte must appear in order. Scoring: +10 word start (string start or
/// after space/underscore), +5 consecutive match, -1 per gap byte
/// (capped at -10 per gap). Returns null when not a subsequence.
/// An empty query matches everything with score 0.
fn fuzzyMatch(text: []const u8, query: []const u8) ?FuzzyResult {
    var result: FuzzyResult = .{
        .score = 0,
        .positions = std.StaticBitSet(64).initEmpty(),
    };
    if (query.len == 0) return result;

    var ti: usize = 0;
    var prev: ?usize = null;
    for (query) |qc| {
        const ql = std.ascii.toLower(qc);
        while (ti < text.len and std.ascii.toLower(text[ti]) != ql) ti += 1;
        if (ti >= text.len) return null;

        if (ti == 0 or text[ti - 1] == ' ' or text[ti - 1] == '_') {
            result.score += 10;
        }
        if (prev) |p| {
            if (ti == p + 1)
                result.score += 5
            else
                result.score -= @intCast(@min(ti - p - 1, 10));
        }
        if (ti < 64) result.positions.set(ti);
        prev = ti;
        ti += 1;
    }
    return result;
}

test "fuzzyMatch subsequence and ordering" {
    // In-order subsequence matches; out-of-order does not.
    try std.testing.expect(fuzzyMatch("New Tab", "nt") != null);
    try std.testing.expect(fuzzyMatch("New Tab", "tn") == null);
    try std.testing.expect(fuzzyMatch("New Tab", "") != null);
    try std.testing.expect(fuzzyMatch("abc", "abcd") == null);
}

test "fuzzyMatch scoring prefers word starts and consecutive runs" {
    // "New Tab": n@0 (word start) + t@4 (word start, gap 3)
    const word_starts = fuzzyMatch("New Tab", "nt").?;
    // "Inspector": n@1, t@6 (no word starts, gap 4)
    const gapped = fuzzyMatch("Inspector", "nt").?;
    try std.testing.expect(word_starts.score > gapped.score);

    // Consecutive beats gapped within the same text.
    const consec = fuzzyMatch("tab", "ta").?;
    const gap = fuzzyMatch("tab", "tb").?;
    try std.testing.expect(consec.score > gap.score);

    // Positions recorded for highlighting.
    try std.testing.expect(word_starts.positions.isSet(0));
    try std.testing.expect(word_starts.positions.isSet(4));
    try std.testing.expect(!word_starts.positions.isSet(1));
}
```

- [ ] **Step 3: トリガー整形を追加(fuzzy テストの後)**

```zig
// ---------------------------------------------------------------------------
// Keybind trigger formatting
// ---------------------------------------------------------------------------

/// Tiny bounded string builder (std.io writers are avoided on purpose;
/// this only ever produces short ASCII-ish labels).
const LabelBuf = struct {
    buf: []u8,
    len: usize = 0,

    fn add(self: *LabelBuf, str: []const u8) void {
        const n = @min(str.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len..][0..n], str[0..n]);
        self.len += n;
    }

    fn addByte(self: *LabelBuf, b: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = b;
            self.len += 1;
        }
    }
};

/// Format a binding trigger like "Ctrl+Shift+T". Mods are ordered
/// Ctrl, Alt, Shift, Win. Returns a slice of `buf`.
fn formatTrigger(buf: []u8, trigger: input.Binding.Trigger) []const u8 {
    var lb: LabelBuf = .{ .buf = buf };
    if (trigger.mods.ctrl) lb.add("Ctrl+");
    if (trigger.mods.alt) lb.add("Alt+");
    if (trigger.mods.shift) lb.add("Shift+");
    if (trigger.mods.super) lb.add("Win+");
    switch (trigger.key) {
        .physical => |k| writeKeyName(&lb, @tagName(k)),
        .unicode => |cp| {
            if (cp < 128) {
                lb.addByte(std.ascii.toUpper(@intCast(cp)));
            } else {
                var utf8: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &utf8) catch 0;
                lb.add(utf8[0..n]);
            }
        },
        .catch_all => lb.add("Any"),
    }
    return lb.buf[0..lb.len];
}

/// Map a physical-key tag name to a display name: "key_a" -> "A",
/// "digit_1" -> "1", "f11" -> "F11", "enter" -> "Enter",
/// "page_up" -> "Page Up".
fn writeKeyName(lb: *LabelBuf, tag: []const u8) void {
    if (std.mem.startsWith(u8, tag, "key_") and tag.len == 5) {
        lb.addByte(std.ascii.toUpper(tag[4]));
        return;
    }
    if (std.mem.startsWith(u8, tag, "digit_")) {
        lb.add(tag[6..]);
        return;
    }
    // Capitalize each '_'-separated word: "page_up" -> "Page Up".
    var it = std.mem.splitScalar(u8, tag, '_');
    var first = true;
    while (it.next()) |word| {
        if (word.len == 0) continue;
        if (!first) lb.addByte(' ');
        lb.addByte(std.ascii.toUpper(word[0]));
        lb.add(word[1..]);
        first = false;
    }
}

test "formatTrigger" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Ctrl+Shift+T", formatTrigger(&buf, .{
        .mods = .{ .ctrl = true, .shift = true },
        .key = .{ .physical = .key_t },
    }));
    try std.testing.expectEqualStrings("F11", formatTrigger(&buf, .{
        .key = .{ .physical = .f11 },
    }));
    try std.testing.expectEqualStrings("Ctrl+1", formatTrigger(&buf, .{
        .mods = .{ .ctrl = true },
        .key = .{ .physical = .digit_1 },
    }));
    try std.testing.expectEqualStrings("Alt+Page Up", formatTrigger(&buf, .{
        .mods = .{ .alt = true },
        .key = .{ .physical = .page_up },
    }));
    try std.testing.expectEqualStrings("Win+Enter", formatTrigger(&buf, .{
        .mods = .{ .super = true },
        .key = .{ .physical = .enter },
    }));
}
```

注: `input.Binding.Trigger` の `key` は `union { physical: input.key.Key, unicode: u21, catch_all }`、`mods` は `shift/ctrl/alt/super: bool`(`src/input/Binding.zig` L1660-1682、`src/input/key_mods.zig` L29-39 確認済み)。物理キーの tag 例: `key_a`, `digit_1`, `enter`, `escape`, `f11`, `page_up`(`src/input/key.zig`)。

- [ ] **Step 4: 検証**

```bash
zig ast-check src/apprt/win32/CommandPalette.zig
zig build -Dtarget=x86_64-windows-gnu
```
Expected: 両方エラーなし(新関数は未使用だが Zig はコンテナレベル未使用関数をエラーにしない)

- [ ] **Step 5: コミット**

```bash
zig fmt src/apprt/win32/CommandPalette.zig
git add src/apprt/win32/CommandPalette.zig
git commit -m "win32: add fuzzy matcher and trigger formatting for command palette"
```

---

### Task 3: UI 全面改修 — オーナードロー化とテーマ追従

**Files:**
- Modify: `src/apprt/win32/CommandPalette.zig`

- [ ] **Step 1: 定数・構造体・フィールドの更新**

(a) 既存の Win32 定数群(L24-59)に追加:

```zig
const LBS_OWNERDRAWFIXED: u32 = 0x0010;
const WM_MEASUREITEM: UINT = 0x002C;
const WM_DRAWITEM: UINT = 0x002B;
const ODS_SELECTED: UINT = 0x0001;

const DRAWITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemAction: UINT,
    itemState: UINT,
    hwndItem: HWND,
    hDC: ?*anyopaque,
    rcItem: sys.RECT,
    itemData: usize,
};

const MEASUREITEMSTRUCT = extern struct {
    CtlType: UINT,
    CtlID: UINT,
    itemID: UINT,
    itemWidth: UINT,
    itemHeight: UINT,
    itemData: usize,
};

// Layout metrics in 96-dpi design units (scaled via self.s()).
const search_row_h: i32 = 44;
const row_h: i32 = 36;
const hint_row_h: i32 = 28;
```

(b) フィールド変更: `filtered: std.ArrayListUnmanaged(usize) = .{},`(L90)を以下に置換し、フィールドを追加:

```zig
/// Filtered + scored commands, best match first.
filtered: std.ArrayListUnmanaged(Match) = .{},

/// Per-open resources (created in open(), freed in close()).
font_main: ?*anyopaque = null,
font_small: ?*anyopaque = null,
bg_brush: ?*anyopaque = null,
dpi: u32 = 96,
```

(c) `init()` の構造体リテラルは `.filtered = .{},` のままで型推論されるので変更不要。

(d) 旧テーマグローバル(L361-365)を削除: `BG_COLOR`, `FG_COLOR`, `var dark_brush`, `var ui_font`。`registerClass` 内の `if (dark_brush == null) ...` 行を削除し、`wc.hbrBackground = dark_brush;` を `wc.hbrBackground = null;` に変更(背景は WM_ERASEBKGND で塗る)。

(e) ヘルパーを追加(`getPalette` の近く):

```zig
/// Theme palette derived fresh from the config (follows reloads).
fn palette(self: *const CommandPalette) TitleBar.Palette {
    const bg = self.app.config.background;
    const fg = self.app.config.foreground;
    return TitleBar.Palette.derive(
        .{ .r = bg.r, .g = bg.g, .b = bg.b },
        .{ .r = fg.r, .g = fg.g, .b = fg.b },
    );
}

/// Scale a 96-dpi design value to the popup's DPI.
fn s(self: *const CommandPalette, v: i32) i32 {
    return @divTrunc(v * @as(i32, @intCast(self.dpi)), 96);
}

/// GDI solid-fill helper.
fn fillRectColor(hdc: ?*anyopaque, rect: sys.RECT, color: u32) void {
    const brush = sys.CreateSolidBrush(color) orelse return;
    defer _ = sys.DeleteObject(brush);
    _ = sys.FillRect(hdc, &rect, brush);
}
```

- [ ] **Step 2: open() を改修**

`open()`(L123-227)を以下に置換:

```zig
fn open(self: *CommandPalette, window: *Window) !void {
    self.target_window = window;
    self.opening = true;
    defer self.opening = false;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyCommandPalette");
    try registerClass();

    // Position the popup centered on the parent window.
    const parent = window.hwnd orelse return error.NoParent;
    self.dpi = sys.GetDpiForWindow(parent);
    var parent_rect: sys.RECT = std.mem.zeroes(sys.RECT);
    _ = GetWindowRect(parent, &parent_rect);
    const parent_w = parent_rect.right - parent_rect.left;
    const parent_h = parent_rect.bottom - parent_rect.top;
    const width: i32 = @min(self.s(620), parent_w - 40);
    const height: i32 = @min(self.s(420), parent_h - 60);
    const x = parent_rect.left + @divTrunc(parent_w - width, 2);
    const y = parent_rect.top + @divTrunc(parent_h - height, 4);

    const pal = self.palette();
    const hinstance = sys.GetModuleHandleW(null);
    self.hwnd = CreateWindowExW(
        WS_EX_TOOLWINDOW,
        class_name,
        std.unicode.utf8ToUtf16LeStringLiteral("Command Palette"),
        WS_POPUP,
        x,
        y,
        width,
        height,
        parent,
        null,
        hinstance,
        null,
    ) orelse return error.Win32Error;
    errdefer {
        if (self.hwnd) |h| {
            _ = DestroyWindow(h);
            self.hwnd = null;
            self.edit_hwnd = null;
            self.list_hwnd = null;
        }
    }

    // Store `self` on the window so the wndProc can access it.
    _ = SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // Win11 rounded corners + theme border color (no-ops on Win10).
    const corner: i32 = sys.DWMWCP_ROUND;
    _ = sys.DwmSetWindowAttribute(
        self.hwnd.?,
        sys.DWMWA_WINDOW_CORNER_PREFERENCE,
        &corner,
        @sizeOf(i32),
    );
    const border_color: u32 = pal.outline.colorref();
    _ = sys.DwmSetWindowAttribute(
        self.hwnd.?,
        sys.DWMWA_BORDER_COLOR,
        &border_color,
        @sizeOf(u32),
    );

    // Per-open theme resources.
    self.bg_brush = sys.CreateSolidBrush(pal.bar_bg.colorref());
    self.font_main = sys.CreateFontW(
        -self.s(15),
        0, 0, 0, 400, 0, 0, 0, 1, 0, 0,
        5, // CLEARTYPE_QUALITY
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );
    self.font_small = sys.CreateFontW(
        -self.s(11),
        0, 0, 0, 400, 0, 0, 0, 1, 0, 0,
        5, // CLEARTYPE_QUALITY
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI"),
    );

    // Borderless search input.
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const edit_h = self.s(22);
    self.edit_hwnd = CreateWindowExW(
        0,
        edit_class,
        std.unicode.utf8ToUtf16LeStringLiteral(""),
        WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
        self.s(16),
        @divTrunc(self.s(search_row_h) - edit_h, 2),
        width - self.s(32),
        edit_h,
        self.hwnd,
        @ptrFromInt(EDIT_ID),
        hinstance,
        null,
    ) orelse return error.Win32Error;

    // Owner-drawn results list.
    const listbox_class = std.unicode.utf8ToUtf16LeStringLiteral("LISTBOX");
    const list_y = self.s(search_row_h) + 1;
    self.list_hwnd = CreateWindowExW(
        0,
        listbox_class,
        null,
        WS_CHILD | WS_VISIBLE | WS_VSCROLL | LBS_NOTIFY | LBS_NOINTEGRALHEIGHT | LBS_OWNERDRAWFIXED,
        self.s(6),
        list_y,
        width - self.s(12),
        height - list_y - self.s(hint_row_h),
        self.hwnd,
        @ptrFromInt(LIST_ID),
        hinstance,
        null,
    ) orelse return error.Win32Error;

    // Dark scrollbar to match the panel (best-effort).
    if (pal.bar_bg.isDark()) {
        _ = sys.SetWindowTheme(
            self.list_hwnd.?,
            std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer"),
            null,
        );
    }

    if (self.font_main) |font| {
        if (self.edit_hwnd) |eh| _ = SendMessageW(eh, WM_SETFONT, @intFromPtr(font), 1);
    }

    // Populate with all commands initially.
    self.filter("") catch {};

    _ = ShowWindow(self.hwnd.?, 1); // SW_SHOWNORMAL
    if (self.edit_hwnd) |eh| _ = SetFocus(eh);
}
```

- [ ] **Step 3: close() にリソース解放を追加**

`close()`(L229-240)を以下に置換:

```zig
pub fn close(self: *CommandPalette) void {
    if (self.hwnd) |h| {
        _ = DestroyWindow(h);
        self.hwnd = null;
        self.edit_hwnd = null;
        self.list_hwnd = null;
        if (self.font_main) |f| _ = sys.DeleteObject(f);
        if (self.font_small) |f| _ = sys.DeleteObject(f);
        if (self.bg_brush) |b| _ = sys.DeleteObject(b);
        self.font_main = null;
        self.font_small = null;
        self.bg_brush = null;
        // Return focus to the target window's focused surface.
        if (self.target_window) |w| {
            if (w.focused_surface) |s| _ = SetFocus(s.hwnd);
        }
    }
}
```

- [ ] **Step 4: filter() / executeSelected() を Match ベースに改修**

`filter()`(L242-264)を以下に置換:

```zig
fn filter(self: *CommandPalette, query: []const u8) !void {
    self.filtered.clearRetainingCapacity();

    for (input.command.defaults, 0..) |cmd, i| {
        if (fuzzyMatch(cmd.title, query)) |m| {
            try self.filtered.append(self.alloc, .{
                .cmd_idx = i,
                .score = m.score,
                .positions = m.positions,
            });
        } else if (fuzzyMatch(@tagName(cmd.action), query)) |m| {
            // Action-name match: slightly lower priority, no title
            // highlight (positions refer to the action string).
            try self.filtered.append(self.alloc, .{
                .cmd_idx = i,
                .score = m.score - 5,
                .positions = std.StaticBitSet(64).initEmpty(),
            });
        }
    }

    // Best match first; stable for equal scores (definition order).
    if (query.len > 0) {
        std.mem.sort(Match, self.filtered.items, {}, struct {
            fn lessThan(_: void, a: Match, b: Match) bool {
                if (a.score != b.score) return a.score > b.score;
                return a.cmd_idx < b.cmd_idx;
            }
        }.lessThan);
    }

    if (self.list_hwnd) |lb| {
        _ = SendMessageW(lb, LB_RESETCONTENT, 0, 0);
        // Owner-drawn without LBS_HASSTRINGS: items carry no data, the
        // index into self.filtered is all WM_DRAWITEM needs.
        for (self.filtered.items) |_| {
            _ = SendMessageW(lb, LB_ADDSTRING, 0, 0);
        }
        if (self.filtered.items.len > 0) {
            _ = SendMessageW(lb, LB_SETCURSEL, 0, 0);
        }
        // Hide the empty list so the parent can show a message instead.
        _ = ShowWindow(lb, if (self.filtered.items.len == 0) 0 else 1);
    }
    if (self.hwnd) |h| _ = sys.InvalidateRect(h, null, 1);
}
```

`executeSelected()` 内(L275)の `const cmd_idx = self.filtered.items[@intCast(sel)];` を:

```zig
    const cmd_idx = self.filtered.items[@intCast(sel)].cmd_idx;
```

`matchesQuery` 関数(L266-269)は不要になるので削除。

- [ ] **Step 5: wndProc を改修(色・オーナードロー・クローム描画)**

`wndProc` の `WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX, WM_CTLCOLORSTATIC` case(L397-405)を以下に置換し、新しい case を追加:

```zig
        WM_CTLCOLOREDIT, WM_CTLCOLORLISTBOX, WM_CTLCOLORSTATIC => {
            const self = getPalette(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            const pal = self.palette();
            const hdc: ?*anyopaque = @ptrFromInt(wparam);
            _ = SetTextColor(hdc, pal.text_active.colorref());
            _ = SetBkColor(hdc, pal.bar_bg.colorref());
            const brush = self.bg_brush orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            // @bitCast preserves the bit pattern (pointer may have high bit set)
            return @bitCast(@intFromPtr(brush));
        },
        sys.WM_ERASEBKGND => {
            const self = getPalette(hwnd) orelse return 0;
            const brush = self.bg_brush orelse return 0;
            var rc: sys.RECT = std.mem.zeroes(sys.RECT);
            _ = sys.GetClientRect(hwnd, &rc);
            const hdc: ?*anyopaque = @ptrFromInt(wparam);
            _ = sys.FillRect(hdc, &rc, brush);
            return 1;
        },
        WM_MEASUREITEM => {
            const self = getPalette(hwnd) orelse return 0;
            const mis: *MEASUREITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            mis.itemHeight = @intCast(self.s(row_h));
            return 1;
        },
        WM_DRAWITEM => {
            const self = getPalette(hwnd) orelse return 0;
            const dis: *const DRAWITEMSTRUCT = @ptrFromInt(@as(usize, @bitCast(lparam)));
            self.drawItem(dis);
            return 1;
        },
        sys.WM_PAINT => {
            const self = getPalette(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            self.paintChrome(hwnd);
            return 0;
        },
```

- [ ] **Step 6: 描画関数を追加(wndProc の後)**

```zig
/// Paint the popup chrome: separators, the bottom hint row, and the
/// empty-state message when no command matches.
fn paintChrome(self: *CommandPalette, hwnd: HWND) void {
    var ps: sys.PAINTSTRUCT = std.mem.zeroes(sys.PAINTSTRUCT);
    const hdc = sys.BeginPaint(hwnd, &ps);
    defer _ = sys.EndPaint(hwnd, &ps);

    var rc: sys.RECT = std.mem.zeroes(sys.RECT);
    _ = sys.GetClientRect(hwnd, &rc);
    const pal = self.palette();

    _ = sys.SetBkMode(hdc, sys.TRANSPARENT);

    // 1px separator under the search row.
    const sep_y = self.s(search_row_h);
    fillRectColor(hdc, .{ .left = 0, .top = sep_y, .right = rc.right, .bottom = sep_y + 1 }, pal.outline.colorref());

    // Bottom hint row with its own separator.
    const hint_top = rc.bottom - self.s(hint_row_h);
    fillRectColor(hdc, .{ .left = 0, .top = hint_top, .right = rc.right, .bottom = hint_top + 1 }, pal.outline.colorref());
    if (self.font_small) |f| _ = sys.SelectObject(hdc, f);
    _ = sys.SetTextColor(hdc, pal.text_inactive.colorref());
    var hint_rc: sys.RECT = .{
        .left = self.s(16),
        .top = hint_top,
        .right = rc.right - self.s(16),
        .bottom = rc.bottom,
    };
    const hint = std.unicode.utf8ToUtf16LeStringLiteral("↑↓ Select      Enter Run      Esc Dismiss");
    _ = sys.DrawTextW(hdc, hint, @intCast(hint.len), &hint_rc, sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_NOPREFIX);

    // Empty-state message where the (hidden) list would be.
    if (self.filtered.items.len == 0) {
        if (self.font_main) |f| _ = sys.SelectObject(hdc, f);
        var msg_rc: sys.RECT = .{ .left = 0, .top = sep_y, .right = rc.right, .bottom = hint_top };
        const text = std.unicode.utf8ToUtf16LeStringLiteral("No matching commands");
        _ = sys.DrawTextW(hdc, text, @intCast(text.len), &msg_rc, sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_CENTER | sys.DT_NOPREFIX);
    }
}

/// Owner-draw a single result row: optional selection pill, the
/// command title with fuzzy-match highlight, and keybind keycaps.
fn drawItem(self: *CommandPalette, dis: *const DRAWITEMSTRUCT) void {
    if (dis.itemID == 0xFFFFFFFF) return;
    const idx: usize = dis.itemID;
    if (idx >= self.filtered.items.len) return;
    const m = self.filtered.items[idx];
    const cmd = input.command.defaults[m.cmd_idx];
    const pal = self.palette();
    const hdc = dis.hDC;
    const selected = (dis.itemState & ODS_SELECTED) != 0;

    // Row background, then the rounded selection pill. fillRoundedRect
    // commits its GDI+ batch before returning, so the GDI text below
    // is guaranteed to draw on top.
    fillRectColor(hdc, dis.rcItem, pal.bar_bg.colorref());
    if (selected) {
        var pill = dis.rcItem;
        pill.left += self.s(4);
        pill.right -= self.s(4);
        pill.top += self.s(2);
        pill.bottom -= self.s(2);
        TitleBar.fillRoundedRect(hdc, pal.selection.argb(), pill, self.s(8));
    }

    _ = sys.SetBkMode(hdc, sys.TRANSPARENT);

    // Keybind keycaps on the right (if the action has a binding).
    var text_right = dis.rcItem.right - self.s(14);
    if (self.app.config.keybind.set.getTrigger(cmd.action)) |trigger| {
        var tbuf: [64]u8 = undefined;
        const label = formatTrigger(&tbuf, trigger);
        text_right = self.drawKeycaps(hdc, &pal, dis.rcItem, label) - self.s(10);
    }

    // Title with fuzzy-match highlight.
    if (self.font_main) |f| _ = sys.SelectObject(hdc, f);
    self.drawHighlightedTitle(hdc, &pal, cmd.title, m.positions, dis.rcItem, text_right, selected);
}

/// Draw "Ctrl+Shift+T" as keycap chips, right-aligned inside `rc`.
/// Returns the x coordinate of the leftmost chip.
fn drawKeycaps(
    self: *CommandPalette,
    hdc: ?*anyopaque,
    pal: *const TitleBar.Palette,
    rc: sys.RECT,
    label: []const u8,
) i32 {
    if (self.font_small) |f| _ = sys.SelectObject(hdc, f);

    const pad = self.s(7);
    const gap = self.s(4);
    const cap_h = self.s(18);

    // Measure all parts first to right-align the group.
    var widths: [8]i32 = undefined;
    var total: i32 = 0;
    var count: usize = 0;
    var it = std.mem.splitScalar(u8, label, '+');
    while (it.next()) |part| {
        if (count >= widths.len) break;
        var wbuf: [32]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, part) catch 0;
        var size: sys.SIZE = .{ .cx = 0, .cy = 0 };
        _ = sys.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        widths[count] = size.cx + 2 * pad;
        total += widths[count];
        count += 1;
    }
    if (count == 0) return rc.right;
    total += gap * @as(i32, @intCast(count - 1));

    var x = rc.right - self.s(14) - total;
    const start_x = x;
    const cy = @divTrunc(rc.top + rc.bottom - cap_h, 2);

    it = std.mem.splitScalar(u8, label, '+');
    var i: usize = 0;
    while (it.next()) |part| {
        if (i >= count) break;
        const cap: sys.RECT = .{ .left = x, .top = cy, .right = x + widths[i], .bottom = cy + cap_h };
        TitleBar.fillRoundedRect(hdc, pal.surface.argb(), cap, self.s(4));
        _ = sys.SetTextColor(hdc, pal.text_inactive.colorref());
        var trc = cap;
        var wbuf: [32]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, part) catch 0;
        _ = sys.DrawTextW(hdc, &wbuf, @intCast(wlen), &trc, sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_CENTER | sys.DT_NOPREFIX);
        x += widths[i] + gap;
        i += 1;
    }
    return start_x;
}

/// Draw the title, coloring fuzzy-matched bytes with the full
/// foreground and the rest with a dimmer tone.
fn drawHighlightedTitle(
    self: *CommandPalette,
    hdc: ?*anyopaque,
    pal: *const TitleBar.Palette,
    title: []const u8,
    positions: std.StaticBitSet(64),
    rc: sys.RECT,
    right_limit: i32,
    selected: bool,
) void {
    // On the selection pill the base text is slightly dimmed so the
    // matched characters still stand out.
    const base = if (selected)
        TitleBar.blend(pal.text_active, pal.selection, 30)
    else
        pal.text_inactive;

    var x = rc.left + self.s(14);
    var i: usize = 0;
    while (i < title.len and x < right_limit) {
        const matched = i < 64 and positions.isSet(i);
        var j = i + 1;
        while (j < title.len) : (j += 1) {
            const jm = j < 64 and positions.isSet(j);
            if (jm != matched) break;
        }

        var wbuf: [128]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, title[i..j]) catch break;
        var size: sys.SIZE = .{ .cx = 0, .cy = 0 };
        _ = sys.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        _ = sys.SetTextColor(hdc, if (matched) pal.text_active.colorref() else base.colorref());
        var trc: sys.RECT = .{
            .left = x,
            .top = rc.top,
            .right = @min(x + size.cx, right_limit),
            .bottom = rc.bottom,
        };
        _ = sys.DrawTextW(hdc, &wbuf, @intCast(wlen), &trc, sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_NOPREFIX | sys.DT_END_ELLIPSIS);
        x += size.cx;
        i = j;
    }
}
```

- [ ] **Step 7: 検証**

```bash
zig ast-check src/apprt/win32/CommandPalette.zig
zig build -Dtarget=x86_64-windows-gnu
grep -n "BG_COLOR\|FG_COLOR\|dark_brush\|ui_font\|matchesQuery\|LBS_HASSTRINGS" src/apprt/win32/CommandPalette.zig
```
Expected: ast-check/build 成功、grep はマッチなし

- [ ] **Step 8: コミット**

```bash
zig fmt src/apprt/win32/CommandPalette.zig
git add src/apprt/win32/CommandPalette.zig
git commit -m "win32: modernize command palette (owner-drawn, theme colors, keycaps)"
```

---

### Task 4: 最終検証

**Files:** なし(検証のみ)

- [ ] **Step 1: フォーマットと最終クロスコンパイル**

```bash
zig fmt src/apprt/win32/sys.zig src/apprt/win32/TitleBar.zig src/apprt/win32/CommandPalette.zig
zig build -Dtarget=x86_64-windows-gnu
```
Expected: 差分なし・ビルド成功

- [ ] **Step 2: 変更範囲の確認**

```bash
git diff --stat 1c6eb20c1..HEAD -- src/
```
Expected: sys.zig / TitleBar.zig / CommandPalette.zig のみ(Window.zig・共有コードに変更なし)

- [ ] **Step 3: Windows 実機検証(ユーザー実施)**

`./sync-to-windows.sh` → ビルド → 起動後:

| # | 確認項目 | 期待 |
|---|---|---|
| 1 | Ctrl+Shift+P で開く | テーマ色のパネル、角丸(Win11)、枠線がテーマ色 |
| 2 | 全コマンド表示 | 各行にタイトル + 右端にキーキャップ風キーバインド(バインドなしは非表示) |
| 3 | "nt" と入力 | New Tab が上位、マッチ文字(N, T)が明るい色で強調 |
| 4 | ↑↓ | 選択行が角丸ピルで移動 |
| 5 | Enter / ダブルクリック | コマンド実行してパレットが閉じる |
| 6 | 存在しない文字列 | リストが消え「No matching commands」表示 |
| 7 | Esc / フォーカス喪失 | 閉じる |
| 8 | 下部ヒント行 | 「↑↓ Select / Enter Run / Esc Dismiss」表示 |
| 9 | IME で日本語入力 | 変換ウィンドウが正常、確定後に絞り込み(0 件で message) |
| 10 | スクロールバー | ダークテーマ化されている(失敗時はライトでも許容) |
| 11 | DPI 150% | 行高・フォント・キーキャップがスケール |
| 12 | ライトテーマ設定 | パネルが明るいグレー系で破綻なし |

---

## Self-Review 済み事項

- スペック全要件カバー: ビジュアル(T3)、ファジー検索(T2+T3)、キーバインド表示(T2+T3)、DWM 角丸/枠(T3)、0 件表示(T3)、IME 保全(EDIT 維持)
- 型整合: `Match`/`FuzzyResult`/`formatTrigger`(T2 定義)と T3 での使用が一致。`TitleBar.fillRoundedRect`/`Palette.selection/surface/outline`/`blend`(T1)と T3 の呼び出しが一致
- `LB_ADDSTRING` は LBS_HASSTRINGS なしではデータ値として lparam を保存するだけなので 0 を渡す(描画は filtered のインデックス参照)
- 既知の妥協: タイトルの強調は ASCII 前提(現状の defaults は全 ASCII)。64 文字超のタイトルはハイライト範囲外
