const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const CoreSurface = @import("../../Surface.zig");
const sys = @import("sys.zig");
const App = @import("App.zig");
const Window = @import("Window.zig");
const popup_style = @import("popup_style.zig");
const PopupTheme = popup_style.PopupTheme;

const HWND = sys.HWND;
const UINT = sys.UINT;
const WPARAM = sys.WPARAM;
const LPARAM = sys.LPARAM;
const LRESULT = sys.LRESULT;
const DWORD = sys.DWORD;

const WS_POPUP: u32 = 0x80000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CHILD: u32 = 0x40000000;
const WS_EX_TOOLWINDOW: u32 = 0x00000080;
const ES_AUTOHSCROLL: u32 = 0x0080;

const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_SETFONT: UINT = 0x0030;
const WM_ACTIVATE: UINT = 0x0006;
const EN_CHANGE: u16 = 0x0300;

const VK_ESCAPE: WPARAM = 0x1B;

const WM_CTLCOLOREDIT: UINT = 0x0133;
const VK_RETURN: WPARAM = 0x0D;
const VK_SHIFT: c_int = 0x10;

// Layout metrics in 96-dpi design units.
const panel_w: i32 = 460;
const input_top: i32 = 12;
const input_h: i32 = 36;
const status_h: i32 = 30;
const margin: i32 = 14;

const EDIT_ID: usize = 200;

extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *sys.RECT) callconv(.winapi) sys.BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) sys.BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) sys.BOOL;
extern "user32" fn GetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*]u16, cchMax: c_int) callconv(.winapi) UINT;
extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const u16) callconv(.winapi) sys.BOOL;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.winapi) isize;
alloc: Allocator,
app: *App,
hwnd: ?HWND = null,
edit_hwnd: ?HWND = null,
theme: ?PopupTheme = null,
target_window: ?*Window = null,
target_surface: ?*CoreSurface = null,
opening: bool = false,
total: ?usize = null,
selected: ?usize = null,

pub fn init(alloc: Allocator, app: *App) Self {
    return .{ .alloc = alloc, .app = app };
}

pub fn deinit(self: *Self) void {
    // No end_search notification at app teardown: the surfaces are
    // being torn down anyway.
    self.close(false);
}

pub fn open(self: *Self, window: *Window, surface: *CoreSurface, initial: [:0]const u8) !void {
    if (self.hwnd == null) {
        self.target_window = window;
        self.target_surface = surface;
        self.opening = true;
        defer self.opening = false;

        try registerClass();
        const parent = window.hwnd orelse return error.NoParent;
        var theme = PopupTheme.init(parent, self.app.config);
        errdefer theme.deinit();

        var parent_rect: sys.RECT = std.mem.zeroes(sys.RECT);
        _ = GetWindowRect(parent, &parent_rect);
        const width: i32 = theme.s(panel_w);
        const height: i32 = theme.s(input_top + input_h + status_h);
        const x = parent_rect.left + @divTrunc((parent_rect.right - parent_rect.left) - width, 2);
        const y = parent_rect.top + 20;
        const hinstance = sys.GetModuleHandleW(null);
        self.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchPanel"), std.unicode.utf8ToUtf16LeStringLiteral("Search"), WS_POPUP, x, y, width, height, parent, null, hinstance, null) orelse return error.Win32Error;
        errdefer self.close(false);
        _ = SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

        self.theme = theme;
        theme.bg_brush = null; // ownership moved; silence the errdefer
        theme.input_brush = null;
        theme.font_main = null;
        theme.font_small = null;

        self.theme.?.applyChrome(self.hwnd.?);

        const t = &self.theme.?;
        const edit_h = t.s(20);
        self.edit_hwnd = CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
            std.unicode.utf8ToUtf16LeStringLiteral(""),
            WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
            t.s(margin) + t.s(8),
            t.s(input_top) + @divTrunc(t.s(input_h) - edit_h, 2),
            width - 2 * t.s(margin) - 2 * t.s(8),
            edit_h,
            self.hwnd,
            @ptrFromInt(EDIT_ID),
            hinstance,
            null,
        ) orelse return error.Win32Error;
        if (t.font_main) |font| _ = SendMessageW(self.edit_hwnd.?, WM_SETFONT, @intFromPtr(font), 1);

        _ = ShowWindow(self.hwnd.?, 1);
    } else {
        self.target_window = window;
        self.target_surface = surface;
    }

    try self.setSearchContents(initial);
    self.total = null;
    self.selected = null;
    self.updateStatus();
    if (self.edit_hwnd) |eh| _ = SetFocus(eh);
}

pub fn preTranslateMessage(self: *Self, message: UINT, hwnd: HWND, wparam: WPARAM) bool {
    if (self.hwnd == null) return false;
    if (message != WM_KEYDOWN) return false;
    if (hwnd != self.edit_hwnd) return false;
    switch (wparam) {
        VK_ESCAPE => {
            self.close(true);
            return true;
        },
        VK_RETURN => {
            // Enter = next match, Shift+Enter = previous match.
            if (sys.GetKeyState(VK_SHIFT) < 0)
                self.navigate(.previous)
            else
                self.navigate(.next);
            return true;
        },
        else => return false,
    }
}

pub fn close(self: *Self, notify_core: bool) void {
    if (notify_core) {
        if (self.target_surface) |surface| {
            _ = surface.performBindingAction(.end_search) catch {};
        }
    }
    if (self.hwnd) |h| _ = DestroyWindow(h);
    self.hwnd = null;
    self.edit_hwnd = null;
    if (self.theme) |*t| t.deinit();
    self.theme = null;
    if (self.target_window) |w| {
        if (w.focused_surface) |s| _ = SetFocus(s.hwnd);
    }
}

pub fn setSearchContents(self: *Self, needle: [:0]const u8) !void {
    if (self.edit_hwnd) |eh| {
        const w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, needle);
        defer self.alloc.free(w);
        _ = SetWindowTextW(eh, w.ptr);
    }
    self.performSearch(needle);
}

pub fn setSearchTotal(self: *Self, total: ?usize) void {
    self.total = total;
    self.updateStatus();
}

pub fn setSearchSelected(self: *Self, selected: ?usize) void {
    self.selected = selected;
    self.updateStatus();
}

fn updateStatus(self: *Self) void {
    if (self.hwnd) |h| _ = sys.InvalidateRect(h, null, 0);
}

fn emitSearchChanged(self: *Self) void {
    if (self.hwnd == null or self.target_surface == null) return;
    var buf: [512]u16 = undefined;
    const len = if (self.hwnd) |h| GetDlgItemTextW(h, EDIT_ID, &buf, buf.len) else 0;
    const utf8 = std.unicode.utf16LeToUtf8AllocZ(self.alloc, buf[0..@intCast(len)]) catch return;
    defer self.alloc.free(utf8);
    self.performSearch(utf8);
}

fn performSearch(self: *Self, needle: [:0]const u8) void {
    const surface = self.target_surface orelse return;
    _ = surface.performBindingAction(.{ .search = needle }) catch {};
}

fn navigate(self: *Self, dir: @TypeOf(@as(@import("../../input/Binding.zig").Action, .{ .navigate_search = .next }).navigate_search)) void {
    const surface = self.target_surface orelse return;
    _ = surface.performBindingAction(.{ .navigate_search = dir }) catch {};
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const ptr = GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    const self: *Self = @ptrFromInt(@as(usize, @bitCast(ptr)));
    switch (msg) {
        WM_CTLCOLOREDIT => {
            const t = &(self.theme orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam));
            const hdc: ?*anyopaque = @ptrFromInt(wparam);
            const brush = t.ctlColorInput(hdc) orelse return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
            return @bitCast(@intFromPtr(brush));
        },
        sys.WM_ERASEBKGND => {
            const t = &(self.theme orelse return 0);
            return t.eraseBkgnd(hwnd, wparam);
        },
        sys.WM_PAINT => {
            self.paint(hwnd);
            return 0;
        },
        WM_COMMAND => {
            const id: usize = wparam & 0xFFFF;
            const code: u16 = @truncate((wparam >> 16) & 0xFFFF);
            if (id == EDIT_ID and code == EN_CHANGE) self.emitSearchChanged();
            return 0;
        },
        WM_KEYDOWN => if (wparam == VK_ESCAPE) {
            self.close(true);
            return 0;
        },
        WM_ACTIVATE => {
            if (!self.opening and @as(u16, @truncate(wparam & 0xFFFF)) == 0) self.close(true);
            return 0;
        },
        WM_CLOSE => {
            self.close(true);
            return 0;
        },
        else => {},
    }
    return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn paint(self: *Self, hwnd: HWND) void {
    var ps: sys.PAINTSTRUCT = std.mem.zeroes(sys.PAINTSTRUCT);
    const hdc = sys.BeginPaint(hwnd, &ps);
    defer _ = sys.EndPaint(hwnd, &ps);
    const t = &(self.theme orelse return);

    var rc: sys.RECT = std.mem.zeroes(sys.RECT);
    _ = sys.GetClientRect(hwnd, &rc);

    // Rounded input field.
    t.drawInputBox(hdc, .{
        .left = t.s(margin),
        .top = t.s(input_top),
        .right = rc.right - t.s(margin),
        .bottom = t.s(input_top) + t.s(input_h),
    });

    const bottom_top = t.s(input_top) + t.s(input_h);

    // Match status on the left ("3 / 12", empty until known).
    const old_font = sys.SelectObject(hdc, t.font_small);
    defer _ = sys.SelectObject(hdc, old_font);
    var status_buf: [32]u8 = undefined;
    const status: []const u8 = if (self.total) |total| blk: {
        const sel_1based = if (self.selected) |sel| sel + 1 else 0;
        break :blk std.fmt.bufPrint(&status_buf, "{d} / {d}", .{ sel_1based, total }) catch "";
    } else "";
    t.drawLabel(
        hdc,
        .{ .left = t.s(margin) + t.s(4), .top = bottom_top, .right = @divTrunc(rc.right, 2), .bottom = rc.bottom },
        status,
        t.pal.text_inactive.colorref(),
        sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_NOPREFIX,
    );

    // Key hints, right-aligned.
    const hints: []const popup_style.Hint = &.{
        .{ .key = "Enter", .label = "Next" },
        .{ .key = "Shift+Enter", .label = "Prev" },
        .{ .key = "Esc", .label = "Close" },
    };
    const hints_w = t.measureHints(hdc, hints);
    t.drawHints(
        hdc,
        .{ .left = rc.right - t.s(margin) - hints_w, .top = bottom_top, .right = rc.right - t.s(margin), .bottom = rc.bottom },
        hints,
    );
}

var class_registered = false;

fn registerClass() !void {
    if (class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttySearchPanel");
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = sys.GetModuleHandleW(null),
        .hIcon = null,
        .hCursor = sys.LoadCursorW(null, sys.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = null,
    };
    if (sys.RegisterClassExW(&wc) == 0) return error.Win32Error;
    class_registered = true;
}
