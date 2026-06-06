const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
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

const WM_CTLCOLOREDIT: UINT = 0x0133;

// Layout metrics in 96-dpi design units.
const dlg_w: i32 = 420;
const head_h: i32 = 34;
const input_h: i32 = 36;
const hint_h: i32 = 32;
const margin: i32 = 14;

const WM_COMMAND: UINT = 0x0111;
const WM_CLOSE: UINT = 0x0010;
const WM_KEYDOWN: UINT = 0x0100;
const WM_SETFONT: UINT = 0x0030;
const WM_ACTIVATE: UINT = 0x0006;

const VK_ESCAPE: WPARAM = 0x1B;
const VK_RETURN: WPARAM = 0x0D;

const EDIT_ID: usize = 100;

extern "user32" fn CreateWindowExW(dwExStyle: DWORD, lpClassName: ?[*:0]const u16, lpWindowName: ?[*:0]const u16, dwStyle: DWORD, x: i32, y: i32, nWidth: i32, nHeight: i32, hWndParent: ?HWND, hMenu: ?*anyopaque, hInstance: ?*anyopaque, lpParam: ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn SendMessageW(hWnd: HWND, msg: UINT, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn SetFocus(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn GetWindowRect(hWnd: HWND, lpRect: *sys.RECT) callconv(.winapi) sys.BOOL;
extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) sys.BOOL;
extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) sys.BOOL;
extern "user32" fn GetDlgItemTextW(hDlg: HWND, nIDDlgItem: c_int, lpString: [*]u16, cchMax: c_int) callconv(.winapi) UINT;
extern "user32" fn GetWindowLongPtrW(hWnd: HWND, nIndex: c_int) callconv(.winapi) isize;
extern "user32" fn SetWindowLongPtrW(hWnd: HWND, nIndex: c_int, dwNewLong: isize) callconv(.winapi) isize;

pub const Mode = enum { surface_title, tab_title };

alloc: Allocator,
app: *App,
hwnd: ?HWND = null,
edit_hwnd: ?HWND = null,
target_window: ?*Window = null,
target_surface: ?*CoreSurface = null,
mode: Mode = .surface_title,
opening: bool = false,
theme: ?PopupTheme = null,

pub fn init(alloc: Allocator, app: *App) Self {
    return .{ .alloc = alloc, .app = app };
}

pub fn deinit(self: *Self) void {
    self.close();
}

pub fn open(self: *Self, window: *Window, surface: *CoreSurface, mode: Mode, initial: [:0]const u8) !void {
    if (self.hwnd != null) self.close();
    self.target_window = window;
    self.target_surface = surface;
    self.mode = mode;
    self.opening = true;
    defer self.opening = false;

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTextPrompt");
    try registerClass();

    const parent = window.hwnd orelse return error.NoParent;
    var theme = PopupTheme.init(parent, self.app.config);
    errdefer theme.deinit();

    var parent_rect: sys.RECT = std.mem.zeroes(sys.RECT);
    _ = GetWindowRect(parent, &parent_rect);
    const width: i32 = theme.s(dlg_w);
    const height: i32 = theme.s(head_h + input_h + hint_h);
    const x = parent_rect.left + @divTrunc((parent_rect.right - parent_rect.left) - width, 2);
    const y = parent_rect.top + @divTrunc((parent_rect.bottom - parent_rect.top) - height, 3);

    const caption = switch (mode) {
        .surface_title => std.unicode.utf8ToUtf16LeStringLiteral("Set Title"),
        .tab_title => std.unicode.utf8ToUtf16LeStringLiteral("Set Tab Title"),
    };
    const hinstance = sys.GetModuleHandleW(null);
    self.hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, class_name, caption, WS_POPUP, x, y, width, height, parent, null, hinstance, null) orelse return error.Win32Error;
    errdefer self.close();
    _ = SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));

    // The wndProc reads self.theme for colors from here on.
    self.theme = theme;
    theme.bg_brush = null; // ownership moved; silence the errdefer
    theme.input_brush = null;
    theme.font_main = null;
    theme.font_small = null;

    self.theme.?.applyChrome(self.hwnd.?);

    // Borderless EDIT inside the rounded input box drawn by WM_PAINT.
    const t = &self.theme.?;
    const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
    const initial_w = try std.unicode.utf8ToUtf16LeAllocZ(self.alloc, initial);
    defer self.alloc.free(initial_w);
    const edit_h = t.s(20);
    self.edit_hwnd = CreateWindowExW(
        0,
        edit_class,
        initial_w.ptr,
        WS_CHILD | WS_VISIBLE | ES_AUTOHSCROLL,
        t.s(margin) + t.s(8),
        t.s(head_h) + @divTrunc(t.s(input_h) - edit_h, 2),
        width - 2 * t.s(margin) - 2 * t.s(8),
        edit_h,
        self.hwnd,
        @ptrFromInt(EDIT_ID),
        hinstance,
        null,
    ) orelse return error.Win32Error;
    if (t.font_main) |font| _ = SendMessageW(self.edit_hwnd.?, WM_SETFONT, @intFromPtr(font), 1);

    _ = ShowWindow(self.hwnd.?, 1);
    if (self.edit_hwnd) |eh| {
        _ = SetFocus(eh);
        // Select-all so typing replaces the current title.
        _ = SendMessageW(eh, 0x00B1, 0, -1); // EM_SETSEL
    }
}

pub fn close(self: *Self) void {
    if (self.hwnd) |h| _ = DestroyWindow(h);
    self.hwnd = null;
    self.edit_hwnd = null;
    if (self.theme) |*t| t.deinit();
    self.theme = null;
    if (self.target_window) |w| {
        if (w.focused_surface) |s| _ = SetFocus(s.hwnd);
    }
}

fn accept(self: *Self) void {
    const target = self.target_surface orelse return self.close();
    var buf: [512]u16 = undefined;
    const len = if (self.hwnd) |h| GetDlgItemTextW(h, EDIT_ID, &buf, buf.len) else 0;
    const utf8 = std.unicode.utf16LeToUtf8AllocZ(self.alloc, buf[0..@intCast(len)]) catch return self.close();
    defer self.alloc.free(utf8);
    _ = switch (self.mode) {
        .surface_title => self.app.performAction(.{ .surface = target }, .set_title, .{ .title = utf8 }) catch false,
        .tab_title => self.app.performAction(.{ .surface = target }, .set_tab_title, .{ .title = utf8 }) catch false,
    };
    self.close();
}

pub fn preTranslateMessage(self: *Self, message: UINT, hwnd: HWND, wparam: WPARAM) bool {
    if (self.hwnd == null) return false;
    if (message != WM_KEYDOWN) return false;
    if (hwnd != self.edit_hwnd) return false;
    switch (wparam) {
        VK_RETURN => {
            self.accept();
            return true;
        },
        VK_ESCAPE => {
            self.close();
            return true;
        },
        else => return false,
    }
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
        WM_KEYDOWN => {
            if (wparam == VK_ESCAPE) {
                self.close();
                return 0;
            }
        },
        WM_ACTIVATE => {
            if (!self.opening and @as(u16, @truncate(wparam & 0xFFFF)) == 0) self.close();
            return 0;
        },
        WM_CLOSE => {
            self.close();
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

    // Heading.
    const old_font = sys.SelectObject(hdc, t.font_main);
    defer _ = sys.SelectObject(hdc, old_font);
    const heading: []const u8 = switch (self.mode) {
        .surface_title => "Set Title",
        .tab_title => "Set Tab Title",
    };
    t.drawLabel(
        hdc,
        .{ .left = t.s(margin) + t.s(4), .top = 0, .right = rc.right - t.s(margin), .bottom = t.s(head_h) },
        heading,
        t.pal.text_active.colorref(),
        sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_NOPREFIX,
    );

    // Rounded input field (the EDIT sits inside).
    t.drawInputBox(hdc, .{
        .left = t.s(margin),
        .top = t.s(head_h),
        .right = rc.right - t.s(margin),
        .bottom = t.s(head_h) + t.s(input_h),
    });

    // Key hints.
    t.drawHints(
        hdc,
        .{ .left = t.s(margin) + t.s(4), .top = t.s(head_h) + t.s(input_h), .right = rc.right - t.s(margin), .bottom = rc.bottom },
        &.{
            .{ .key = "Enter", .label = "Save" },
            .{ .key = "Esc", .label = "Cancel" },
        },
    );
}

var class_registered = false;

fn registerClass() !void {
    if (class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyTextPrompt");
    const hinstance = sys.GetModuleHandleW(null);
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW,
        .lpfnWndProc = wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
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
