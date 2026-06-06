//! Native Win32 command palette. A modal popup window with an edit control
//! for filtering and a list box showing matching commands.
const CommandPalette = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const input = @import("../../input.zig");
const sys = @import("sys.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const TitleBar = @import("TitleBar.zig");

const log = std.log.scoped(.win32_cmd_palette);

const HWND = sys.HWND;
const LRESULT = sys.LRESULT;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;
const UINT = sys.UINT;
const DWORD = sys.DWORD;

// Win32 constants
const WS_POPUP: u32 = 0x80000000;
const WS_BORDER: u32 = 0x00800000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CHILD: u32 = 0x40000000;
const WS_VSCROLL: u32 = 0x00200000;
const WS_EX_TOPMOST: u32 = 0x00000008;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const ES_AUTOHSCROLL: u32 = 0x0080;
const LBS_NOTIFY: u32 = 0x0001;
const LBS_NOINTEGRALHEIGHT: u32 = 0x0100;
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

const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_DESTROY: UINT = 0x0002;
const WM_KEYDOWN: UINT = 0x0100;
const WM_CHAR: UINT = 0x0102;
const WM_ACTIVATE: UINT = 0x0006;
const WM_SETFONT: UINT = 0x0030;

const LB_RESETCONTENT: UINT = 0x0184;
const LB_ADDSTRING: UINT = 0x0180;
const LB_SETCURSEL: UINT = 0x0186;
const LB_GETCURSEL: UINT = 0x0188;
const LB_GETCOUNT: UINT = 0x018B;

const EN_CHANGE: u16 = 0x0300;
const LBN_DBLCLK: u16 = 2;

const VK_ESCAPE: WPARAM = 0x1B;
const VK_RETURN: WPARAM = 0x0D;
const VK_UP: WPARAM = 0x26;
const VK_DOWN: WPARAM = 0x28;

const EDIT_ID: usize = 100;
const LIST_ID: usize = 101;

// Additional externs
extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetParent(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *sys.RECT) callconv(.winapi) sys.BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) sys.BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) sys.BOOL;
extern "user32" fn GetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*]u16, cchMax: c_int) callconv(.winapi) UINT;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.winapi) isize;

/// Allocator
alloc: Allocator,

/// The app that owns this palette
app: *App,

/// The currently open popup window (null when closed)
hwnd: ?HWND = null,

/// Child controls
edit_hwnd: ?HWND = null,
list_hwnd: ?HWND = null,

/// The window that opened this palette (where the command will execute)
target_window: ?*Window = null,

/// Filtered + scored commands, best match first.
filtered: std.ArrayListUnmanaged(Match) = .{},

/// Per-open resources (created in open(), freed in close()).
font_main: ?*anyopaque = null,
font_small: ?*anyopaque = null,
bg_brush: ?*anyopaque = null,
dpi: u32 = 96,

/// True while open() is in progress; blocks WM_ACTIVATE-driven close.
opening: bool = false,

pub fn init(alloc: Allocator, app: *App) CommandPalette {
    return .{
        .alloc = alloc,
        .app = app,
        .hwnd = null,
        .edit_hwnd = null,
        .list_hwnd = null,
        .target_window = null,
        .filtered = .{},
        .opening = false,
    };
}

pub fn deinit(self: *CommandPalette) void {
    self.close();
    self.filtered.deinit(self.alloc);
}

pub fn toggle(self: *CommandPalette, window: *Window) void {
    if (self.hwnd != null) {
        self.close();
    } else {
        self.open(window) catch |err| {
            log.err("failed to open command palette: {}", .{err});
        };
    }
}

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
        if (self.bg_brush) |b| _ = sys.DeleteObject(b);
        if (self.font_main) |f| _ = sys.DeleteObject(f);
        if (self.font_small) |f| _ = sys.DeleteObject(f);
        self.bg_brush = null;
        self.font_main = null;
        self.font_small = null;
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
    self.font_small = sys.CreateFontW(
        -self.s(11),
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
            if (w.focused_surface) |surf| _ = SetFocus(surf.hwnd);
        }
    }
}

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
        // Owner-drawn: items carry no string data; the index into
        // self.filtered is all WM_DRAWITEM needs.
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

fn executeSelected(self: *CommandPalette) void {
    const lb = self.list_hwnd orelse return;
    // LB_GETCURSEL returns LB_ERR (-1) when there is no selection; keep
    // the raw signed LRESULT so the guard below actually works.
    const sel: isize = SendMessageW(lb, LB_GETCURSEL, 0, 0);
    if (sel < 0 or @as(usize, @intCast(sel)) >= self.filtered.items.len) return;
    const cmd_idx = self.filtered.items[@intCast(sel)].cmd_idx;
    const cmd = input.command.defaults[cmd_idx];

    // Close the palette first so focus returns to the terminal
    const target = self.target_window;
    self.close();

    // Perform the action on the target surface
    _ = self.app;
    if (target) |w| {
        const surface = w.getFocusedSurface() orelse return;
        if (surface.core_surface) |core| {
            _ = core.performBindingAction(cmd.action) catch |err| {
                log.err("failed to execute command {s}: {}", .{ cmd.title, err });
            };
        }
    }
}

extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]u16, nMaxCount: c_int) callconv(.winapi) c_int;

/// Called by App.run() before DispatchMessageW to pre-process messages
/// while the command palette is open. Returns true if the message was
/// consumed and should not be dispatched further.
pub fn preTranslateMessage(self: *CommandPalette, msg: UINT, hwnd: HWND, wparam: WPARAM) bool {
    if (self.hwnd == null) return false;
    // Only intercept keys targeted at our edit control
    if (self.edit_hwnd) |eh| {
        if (hwnd != eh) return false;
    } else return false;

    if (msg != WM_KEYDOWN) return false;

    switch (wparam) {
        VK_ESCAPE => {
            self.close();
            return true;
        },
        VK_RETURN => {
            self.executeSelected();
            return true;
        },
        VK_UP, VK_DOWN => {
            const lb = self.list_hwnd orelse return true;
            const count: isize = SendMessageW(lb, LB_GETCOUNT, 0, 0);
            if (count <= 0) return true;
            var sel: isize = SendMessageW(lb, LB_GETCURSEL, 0, 0);
            if (wparam == VK_UP and sel > 0) sel -= 1;
            if (wparam == VK_DOWN and sel < count - 1) sel += 1;
            _ = SendMessageW(lb, LB_SETCURSEL, @bitCast(sel), 0);
            return true;
        },
        else => return false,
    }
}

/// Re-run the filter from the current edit control text.
pub fn refilter(self: *CommandPalette) void {
    const eh = self.edit_hwnd orelse return;
    var buf: [256]u16 = undefined;
    const len_raw = GetWindowTextW(eh, &buf, buf.len);
    const len: usize = if (len_raw > 0) @intCast(len_raw) else 0;
    var u8_buf: [1024]u8 = undefined;
    const u8_len = std.unicode.utf16LeToUtf8(&u8_buf, buf[0..len]) catch 0;
    self.filter(u8_buf[0..u8_len]) catch {};
}
extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn SetTextColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
extern "gdi32" fn SetBkColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;
extern "gdi32" fn CreateFontW(
    cHeight: i32,
    cWidth: i32,
    cEscapement: i32,
    cOrientation: i32,
    cWeight: i32,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: [*:0]const u16,
) callconv(.winapi) ?*anyopaque;

var class_registered: bool = false;

fn registerClass() !void {
    if (class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyCommandPalette");
    const hinstance = sys.GetModuleHandleW(null);
    var wc: sys.WNDCLASSEXW = std.mem.zeroes(sys.WNDCLASSEXW);
    wc.cbSize = @sizeOf(sys.WNDCLASSEXW);
    wc.lpfnWndProc = wndProc;
    wc.hInstance = hinstance;
    wc.hCursor = sys.LoadCursorW(null, sys.IDC_ARROW);
    wc.hbrBackground = null;
    wc.lpszClassName = class_name;
    if (sys.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}

fn getPalette(hwnd: HWND) ?*CommandPalette {
    const ptr = GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(ptr)));
}

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

const WM_CTLCOLOREDIT: UINT = 0x0133;
const WM_CTLCOLORLISTBOX: UINT = 0x0134;
const WM_CTLCOLORSTATIC: UINT = 0x0138;

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    switch (msg) {
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
        WM_COMMAND => {
            const self = getPalette(hwnd) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            const ctl_id: u16 = @truncate(wparam & 0xFFFF);
            const notify: u16 = @truncate((wparam >> 16) & 0xFFFF);
            if (ctl_id == EDIT_ID and notify == EN_CHANGE) {
                // Get current text and filter
                var buf: [256]u16 = undefined;
                const len = GetDlgItemTextW(hwnd, EDIT_ID, &buf, buf.len);
                var u8_buf: [1024]u8 = undefined;
                const u8_len = std.unicode.utf16LeToUtf8(&u8_buf, buf[0..len]) catch 0;
                self.filter(u8_buf[0..u8_len]) catch {};
            } else if (ctl_id == LIST_ID and notify == LBN_DBLCLK) {
                self.executeSelected();
            }
            return 0;
        },
        WM_CLOSE => {
            if (getPalette(hwnd)) |self| self.close();
            return 0;
        },
        WM_ACTIVATE => {
            // When we lose activation, schedule a close via PostMessage to
            // avoid re-entrancy. `opening` guards against closing during open().
            if ((wparam & 0xFFFF) == 0) { // WA_INACTIVE
                if (getPalette(hwnd)) |self| {
                    if (!self.opening) {
                        _ = sys.PostMessageW(hwnd, WM_CLOSE, 0, 0);
                    }
                }
            }
            return 0;
        },
        else => return sys.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

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
