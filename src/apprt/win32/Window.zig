//! A single top-level Win32 window. Each Window owns one HWND and a set of
//! tabs. Every tab owns its own split tree and active surface state.
const Window = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const apprt = @import("../../apprt.zig");
const configpkg = @import("../../config.zig");
const CoreSurface = @import("../../Surface.zig");
const Surface = @import("Surface.zig");
const SplitTree = @import("SplitTree.zig");
const sys = @import("sys.zig");

const App = @import("App.zig");
const TitleBar = @import("TitleBar.zig");

const HWND = sys.HWND;
const RECT = sys.RECT;
const BOOL = sys.BOOL;
const UINT = sys.UINT;
const DWORD = sys.DWORD;
const LPARAM = sys.LPARAM;
const WPARAM = sys.WPARAM;
const LRESULT = sys.LRESULT;

const WS_CHILD: u32 = 0x40000000;
const WS_VISIBLE: u32 = 0x10000000;
const WS_CLIPCHILDREN: u32 = 0x02000000;
const WM_PAINT: UINT = 0x000F;
const WM_LBUTTONDOWN: UINT = 0x0201;
const WM_LBUTTONUP: UINT = 0x0202;
const WM_MOUSEMOVE: UINT = 0x0200;
const WM_CAPTURECHANGED: UINT = 0x0215;
const WM_SETCURSOR: UINT = 0x0020;
const SW_HIDE: c_int = 0;
const DIVIDER_THICKNESS: i32 = 10;
const IDC_SIZEWE = @as(?[*:0]align(1) const u16, @ptrFromInt(32644));
const IDC_SIZENS = @as(?[*:0]align(1) const u16, @ptrFromInt(32645));

extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?*anyopaque;
extern "gdi32" fn DeleteObject(ho: ?*anyopaque) callconv(.winapi) BOOL;
extern "user32" fn FillRect(hDC: ?*anyopaque, lprc: *const RECT, hbr: ?*anyopaque) callconv(.winapi) c_int;
extern "user32" fn SetCapture(hWnd: HWND) callconv(.winapi) ?HWND;
extern "user32" fn ReleaseCapture() callconv(.winapi) BOOL;
extern "user32" fn SetCursor(hCursor: sys.HCURSOR) callconv(.winapi) sys.HCURSOR;

var divider_class_registered: bool = false;

const DividerState = struct {
    hwnd: HWND,
    window: *Window,
    node: *SplitTree.Node,
    direction: SplitTree.Direction,
    rect: SplitTree.Rect,
    bounds: SplitTree.Rect,
    active: bool = false,
};

const DividerDrag = struct {
    divider: *DividerState,
};

pub const CreateOptions = struct {
    command: ?configpkg.Command = null,
    working_directory: ?configpkg.WorkingDirectory = null,
    title: ?[:0]const u8 = null,
    quick_terminal: bool = false,

    pub const none: @This() = .{};

    pub fn deinit(self: *@This(), alloc: Allocator) void {
        if (self.command) |cmd| cmd.deinit(alloc);
        if (self.working_directory) |wd| switch (wd) {
            .path => |path| alloc.free(path),
            else => {},
        };
        if (self.title) |title| alloc.free(title);
        self.* = .{};
    }
};

const TabState = struct {
    primary_surface: *Surface,
    tree: SplitTree,
    focused_surface: ?*Surface = null,
    title: [:0]const u8,
};

app: *App,
hwnd: ?HWND = null,
titlebar: TitleBar = .{},
primary_surface: *Surface,
tree: ?SplitTree = null,
focused_surface: ?*Surface = null,
surface_initialized: bool = false,
tabs: std.ArrayListUnmanaged(TabState) = .{},
current_tab: usize = 0,
fullscreen: FullscreenState = .{},
quick_terminal: bool = false,
dividers: std.ArrayListUnmanaged(*DividerState) = .{},
drag: ?DividerDrag = null,

const FullscreenState = struct {
    active: bool = false,
    style: i32 = 0,
    ex_style: i32 = 0,
    rect: RECT = std.mem.zeroes(RECT),
};

pub fn create(alloc: Allocator, app: *App, opts: CreateOptions) !*Window {
    const self = try alloc.create(Window);
    errdefer alloc.destroy(self);

    self.* = .{
        .app = app,
        .primary_surface = undefined,
        .quick_terminal = opts.quick_terminal,
    };

    try self.createHwnd(opts.title);
    errdefer {
        if (self.hwnd) |h| _ = sys.DestroyWindow(h);
    }

    // Must be set before setupCustomFrame: the synchronous WM_NCCALCSIZE
    // triggered by SWP_FRAMECHANGED calls getWindow, which reads GWLP_USERDATA.
    _ = sys.SetWindowLongPtrW(self.hwnd.?, sys.GWLP_USERDATA, @bitCast(@intFromPtr(self)));
    self.setupCustomFrame();

    _ = try self.insertTab(0, opts, true);
    if (self.quick_terminal) self.applyQuickTerminalLayout() else self.applyConfiguredWindowSize();
    self.relayout();

    if (self.focused_surface) |surface| {
        _ = sys.SetFocus(surface.hwnd);
        if (surface.core_surface) |core| {
            core.colorSchemeCallback(app.detectColorScheme()) catch {};
        }
    }

    return self;
}

pub fn deinit(self: *Window) void {
    self.destroyDividers();
    self.titlebar.deinit();
    self.syncActiveTabFromWindow();
    for (self.tabs.items) |*tab| self.deinitTab(tab);
    self.tabs.deinit(self.app.alloc);
    self.tree = null;
    self.surface_initialized = false;
    if (self.hwnd) |hwnd| {
        _ = sys.DestroyWindow(hwnd);
        self.hwnd = null;
    }
}

fn createHwnd(self: *Window, title_override: ?[:0]const u8) !void {
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyWindow");
    const hinstance = sys.GetModuleHandleW(null);
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW | sys.CS_OWNDC,
        .lpfnWndProc = App.wndProc,
        .cbClsExtra = 0,
        .cbWndExtra = 0,
        .hInstance = hinstance,
        .hIcon = sys.LoadIconW(hinstance, @ptrFromInt(1)),
        .hCursor = sys.LoadCursorW(null, sys.IDC_ARROW),
        .hbrBackground = null,
        .lpszMenuName = null,
        .lpszClassName = class_name,
        .hIconSm = sys.LoadIconW(hinstance, @ptrFromInt(1)),
    };
    _ = sys.RegisterClassExW(&wc);

    const title = if (title_override) |title_utf8|
        try std.unicode.utf8ToUtf16LeAllocZ(self.app.alloc, title_utf8)
    else
        null;
    defer if (title) |v| self.app.alloc.free(v);

    self.hwnd = sys.CreateWindowExW(
        if (self.quick_terminal) @intCast(sys.WS_EX_TOPMOST) else 0,
        class_name,
        if (title) |v| v.ptr else std.unicode.utf8ToUtf16LeStringLiteral("Ghostty"),
        (if (self.quick_terminal) sys.WS_OVERLAPPEDWINDOW & ~sys.WS_CAPTION_BIT else sys.WS_OVERLAPPEDWINDOW) | WS_CLIPCHILDREN,
        sys.CW_USEDEFAULT,
        sys.CW_USEDEFAULT,
        900,
        650,
        null,
        null,
        hinstance,
        null,
    );
    if (self.hwnd == null) return error.Win32Error;
    _ = sys.ShowWindow(self.hwnd.?, sys.SW_SHOWNORMAL);
    _ = sys.UpdateWindow(self.hwnd.?);
}

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

fn registerDividerClass() !void {
    if (divider_class_registered) return;
    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDivider");
    const hinstance = sys.GetModuleHandleW(null);
    const wc: sys.WNDCLASSEXW = .{
        .cbSize = @sizeOf(sys.WNDCLASSEXW),
        .style = sys.CS_HREDRAW | sys.CS_VREDRAW,
        .lpfnWndProc = dividerWndProc,
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
    divider_class_registered = true;
}

fn dividerWndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    const ptr = sys.GetWindowLongPtrW(hwnd, sys.GWLP_USERDATA);
    if (ptr == 0) return sys.DefWindowProcW(hwnd, msg, wparam, lparam);
    const divider: *DividerState = @ptrFromInt(@as(usize, @bitCast(ptr)));
    return divider.window.handleDividerMessage(divider, hwnd, msg, wparam, lparam);
}

fn destroyDividers(self: *Window) void {
    if (self.drag != null) {
        _ = ReleaseCapture();
        self.drag = null;
    }
    for (self.dividers.items) |divider| {
        _ = sys.DestroyWindow(divider.hwnd);
        self.app.alloc.destroy(divider);
    }
    self.dividers.deinit(self.app.alloc);
}

fn ensureDividerCount(self: *Window, count: usize) !void {
    try registerDividerClass();
    while (self.dividers.items.len < count) {
        const divider = try self.app.alloc.create(DividerState);
        errdefer self.app.alloc.destroy(divider);
        const hwnd = sys.CreateWindowExW(
            0,
            std.unicode.utf8ToUtf16LeStringLiteral("GhosttyDivider"),
            null,
            WS_CHILD | WS_VISIBLE,
            0,
            0,
            0,
            0,
            self.hwnd,
            null,
            sys.GetModuleHandleW(null),
            null,
        ) orelse return error.Win32Error;
        divider.* = .{
            .hwnd = hwnd,
            .window = self,
            .node = undefined,
            .direction = .horizontal,
            .rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
            .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
        };
        _ = sys.SetWindowLongPtrW(hwnd, sys.GWLP_USERDATA, @bitCast(@intFromPtr(divider)));
        try self.dividers.append(self.app.alloc, divider);
    }
}

fn updateDividers(self: *Window, bounds: SplitTree.Rect) void {
    const tree = &(self.tree orelse {
        self.hideAllDividers();
        return;
    });
    var buf: [64]SplitTree.DividerRect = undefined;
    const count = tree.collectDividerRects(bounds, &buf);
    self.ensureDividerCount(count) catch return;

    for (self.dividers.items, 0..) |divider, i| {
        if (i >= count) {
            divider.active = false;
            _ = sys.ShowWindow(divider.hwnd, SW_HIDE);
            continue;
        }
        const info = buf[i];
        divider.node = info.node;
        divider.direction = info.direction;
        divider.rect = info.rect;
        divider.bounds = info.bounds;
        divider.active = true;
        _ = sys.SetWindowPos(
            divider.hwnd,
            null,
            info.rect.x,
            info.rect.y,
            info.rect.w,
            info.rect.h,
            0x0004,
        );
        _ = sys.ShowWindow(divider.hwnd, sys.SW_SHOWNORMAL);
        _ = sys.InvalidateRect(divider.hwnd, null, 1);
    }
}

fn hideAllDividers(self: *Window) void {
    for (self.dividers.items) |divider| {
        divider.active = false;
        _ = sys.ShowWindow(divider.hwnd, SW_HIDE);
    }
}

fn adjustDividerRatio(self: *Window, divider: *DividerState, lparam: LPARAM) void {
    const sp = switch (divider.node.*) {
        .split => |*sp| sp,
        else => return,
    };
    const x: i32 = @as(i16, @truncate(lparam & 0xFFFF));
    const y: i32 = @as(i16, @truncate((lparam >> 16) & 0xFFFF));
    const new_ratio: f32 = switch (divider.direction) {
        .horizontal => blk: {
            if (divider.bounds.w <= DIVIDER_THICKNESS) break :blk sp.ratio;
            const absolute_x = divider.rect.x + x;
            const offset = std.math.clamp(absolute_x - divider.bounds.x, 0, divider.bounds.w);
            break :blk @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(divider.bounds.w));
        },
        .vertical => blk: {
            if (divider.bounds.h <= DIVIDER_THICKNESS) break :blk sp.ratio;
            const absolute_y = divider.rect.y + y;
            const offset = std.math.clamp(absolute_y - divider.bounds.y, 0, divider.bounds.h);
            break :blk @as(f32, @floatFromInt(offset)) / @as(f32, @floatFromInt(divider.bounds.h));
        },
    };
    sp.ratio = std.math.clamp(new_ratio, 0.1, 0.9);
    self.relayout();
}

fn handleDividerMessage(self: *Window, divider: *DividerState, hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) LRESULT {
    switch (msg) {
        WM_PAINT => {
            var ps: sys.PAINTSTRUCT = std.mem.zeroes(sys.PAINTSTRUCT);
            const hdc = sys.BeginPaint(hwnd, &ps);
            var rect: RECT = std.mem.zeroes(RECT);
            _ = sys.GetClientRect(hwnd, &rect);
            const bg_brush = CreateSolidBrush(0x00E4E4E4);
            if (bg_brush != null) {
                _ = FillRect(hdc, &rect, bg_brush);
                _ = DeleteObject(bg_brush);
            }
            var line_rect = rect;
            if (divider.direction == .horizontal) {
                line_rect.left = @divTrunc(rect.right - rect.left - 2, 2);
                line_rect.right = line_rect.left + 2;
            } else {
                line_rect.top = @divTrunc(rect.bottom - rect.top - 2, 2);
                line_rect.bottom = line_rect.top + 2;
            }
            const line_brush = CreateSolidBrush(0x00858585);
            if (line_brush != null) {
                _ = FillRect(hdc, &line_rect, line_brush);
                _ = DeleteObject(line_brush);
            }
            _ = sys.EndPaint(hwnd, &ps);
            return 0;
        },
        WM_SETCURSOR => {
            _ = SetCursor(sys.LoadCursorW(
                null,
                if (divider.direction == .horizontal) IDC_SIZEWE else IDC_SIZENS,
            ));
            return 1;
        },
        WM_LBUTTONDOWN => {
            self.drag = .{ .divider = divider };
            _ = SetCapture(hwnd);
            self.adjustDividerRatio(divider, lparam);
            return 0;
        },
        WM_MOUSEMOVE => {
            if (self.drag) |drag| {
                if (drag.divider == divider) self.adjustDividerRatio(divider, lparam);
            }
            return 0;
        },
        WM_LBUTTONUP, WM_CAPTURECHANGED => {
            if (self.drag) |drag| {
                if (drag.divider == divider) {
                    self.drag = null;
                    _ = ReleaseCapture();
                }
            }
            return 0;
        },
        else => return sys.DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

fn makeTabTitle(self: *Window, requested: ?[:0]const u8, index: usize) ![:0]const u8 {
    if (requested) |title| return try self.app.alloc.dupeZ(u8, title);
    return try std.fmt.allocPrintSentinel(self.app.alloc, "Tab {d}", .{index + 1}, 0);
}

fn insertTab(self: *Window, raw_index: usize, opts: CreateOptions, select: bool) !usize {
    const alloc = self.app.alloc;
    const surface = try alloc.create(Surface);
    errdefer alloc.destroy(surface);
    surface.* = .{ .hwnd = undefined };

    try surface.init(self.hwnd.?, self.app);
    surface.window = self;
    errdefer surface.deinit();

    try self.initCoreSurface(surface, opts);
    errdefer {
        if (surface.core_surface) |core| {
            core.deinit();
            alloc.destroy(core);
            surface.core_surface = null;
        }
    }

    const tab: TabState = .{
        .primary_surface = surface,
        .tree = try SplitTree.initLeaf(alloc, surface),
        .focused_surface = surface,
        .title = try self.makeTabTitle(opts.title, raw_index),
    };
    errdefer alloc.free(tab.title);

    const index = @min(raw_index, self.tabs.items.len);
    if (self.tabs.items.len > 0) self.syncActiveTabFromWindow();
    try self.tabs.insert(alloc, index, tab);

    if (self.tabs.items.len == 1) {
        self.current_tab = 0;
        self.loadActiveTabIntoWindow();
    } else if (index <= self.current_tab and !select) {
        self.current_tab += 1;
    }

    // Tab indices shifted; stale hover would highlight the wrong tab.
    self.titlebar.hover = .none;
    self.invalidateTitleBar();

    if (select or self.tabs.items.len == 1) {
        try self.activateTab(index);
    } else {
        self.hideTabSurfaces(&self.tabs.items[index]);
    }

    return index;
}

fn deinitTab(self: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    const count = tab.tree.collectLeaves(&leaves);
    for (leaves[0..count]) |surface| {
        self.app.core_app.deleteSurface(surface);
        if (surface.core_surface) |core| {
            core.deinit();
            self.app.alloc.destroy(core);
            surface.core_surface = null;
        }
        surface.deinit();
        self.app.alloc.destroy(surface);
    }
    tab.tree.deinit(self.app.alloc);
    self.app.alloc.free(tab.title);
}

fn syncActiveTabFromWindow(self: *Window) void {
    if (self.tabs.items.len == 0 or self.current_tab >= self.tabs.items.len) return;
    const tab = &self.tabs.items[self.current_tab];
    tab.primary_surface = self.primary_surface;
    tab.tree = self.tree orelse return;
    tab.focused_surface = self.focused_surface orelse self.primary_surface;
}

fn loadActiveTabIntoWindow(self: *Window) void {
    const tab = &self.tabs.items[self.current_tab];
    self.primary_surface = tab.primary_surface;
    self.tree = tab.tree;
    self.focused_surface = tab.focused_surface orelse tab.primary_surface;
    self.surface_initialized = true;
}

fn activeTab(self: *Window) ?*TabState {
    if (self.tabs.items.len == 0 or self.current_tab >= self.tabs.items.len) return null;
    return &self.tabs.items[self.current_tab];
}

pub fn getFocusedSurface(self: *Window) ?*Surface {
    return self.focused_surface orelse if (self.tabs.items.len > 0) self.primary_surface else null;
}

pub fn getActiveTabTitle(self: *Window) ?[:0]const u8 {
    const tab = self.activeTab() orelse return null;
    return tab.title;
}

pub fn setActiveTabTitle(self: *Window, title: [:0]const u8) !void {
    const tab = self.activeTab() orelse return;
    self.app.alloc.free(tab.title);
    tab.title = try self.app.alloc.dupeZ(u8, title);
    self.invalidateTitleBar();
}

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

pub fn invalidateTitleBar(self: *Window) void {
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

fn tabLeaves(tab: *TabState, buf: []*Surface) []const *Surface {
    const count = tab.tree.collectLeaves(buf);
    return buf[0..count];
}

fn hideTabSurfaces(_: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    for (tabLeaves(tab, &leaves)) |surface| {
        surface.setVisible(false);
    }
}

fn showTabSurfaces(_: *Window, tab: *TabState) void {
    var leaves: [64]*Surface = undefined;
    for (tabLeaves(tab, &leaves)) |surface| {
        surface.setVisible(true);
    }
}

fn activateTab(self: *Window, index: usize) !void {
    if (self.tabs.items.len == 0 or index >= self.tabs.items.len) return;
    if (index == self.current_tab and self.tree != null) {
        self.relayout();
        if (self.focused_surface) |surface| _ = sys.SetFocus(surface.hwnd);
        return;
    }

    if (self.tabs.items.len > 0 and self.tree != null and self.current_tab < self.tabs.items.len) {
        self.syncActiveTabFromWindow();
        self.hideTabSurfaces(&self.tabs.items[self.current_tab]);
    }

    self.current_tab = index;
    self.loadActiveTabIntoWindow();
    self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    self.invalidateTitleBar();
    self.relayout();
    if (self.focused_surface) |surface| _ = sys.SetFocus(surface.hwnd);
}

fn findTabIndexForSurface(self: *Window, surface: *Surface) ?usize {
    if (self.tabs.items.len == 0) return null;
    if (self.tree) |tree| {
        if (tree.findLeaf(surface) != null and self.current_tab < self.tabs.items.len) return self.current_tab;
    }
    for (self.tabs.items, 0..) |tab, i| {
        if (i == self.current_tab and self.tree != null) continue;
        if (tab.tree.findLeaf(surface) != null) return i;
    }
    return null;
}

fn closeTabAt(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const was_current = index == self.current_tab;

    if (was_current and self.tree != null) {
        self.syncActiveTabFromWindow();
        self.tree = null;
        self.focused_surface = null;
        self.surface_initialized = false;
    }

    var tab = self.tabs.orderedRemove(index);
    self.deinitTab(&tab);

    if (self.tabs.items.len == 0) {
        self.tree = null;
        self.focused_surface = null;
        self.surface_initialized = false;
        self.app.closeWindow(self);
        return;
    }

    if (index < self.current_tab or self.current_tab >= self.tabs.items.len) {
        self.current_tab = if (self.current_tab == 0) 0 else self.current_tab - 1;
    }

    if (was_current) {
        // Rebind window state to the newly active tab before rebuilding the
        // tab control so any reentrant messages do not see a freed surface.
        self.loadActiveTabIntoWindow();
        // The newly active tab's surfaces may have been hidden by a prior tab
        // switch.  Make them visible now so the window is not blank.
        self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    }

    self.titlebar.hover = .none;
    self.invalidateTitleBar();
    self.activateTab(self.current_tab) catch {};
}

fn closeEmptyTabAt(self: *Window, index: usize) void {
    if (index >= self.tabs.items.len) return;
    const was_current = index == self.current_tab;

    if (was_current) {
        self.tree = null;
        self.focused_surface = null;
        self.surface_initialized = false;
    }

    const tab = self.tabs.orderedRemove(index);
    self.app.alloc.free(tab.title);

    if (self.tabs.items.len == 0) {
        self.app.closeWindow(self);
        return;
    }

    if (index < self.current_tab or self.current_tab >= self.tabs.items.len) {
        self.current_tab = if (self.current_tab == 0) 0 else self.current_tab - 1;
    }

    if (was_current) {
        // Rebind window state to the newly active tab before rebuilding the
        // tab control so any reentrant messages do not see a freed surface.
        self.loadActiveTabIntoWindow();
        // The newly active tab's surfaces may have been hidden by a prior tab
        // switch.  Make them visible now so the window is not blank.
        self.showTabSurfaces(&self.tabs.items[self.current_tab]);
    }

    self.titlebar.hover = .none;
    self.invalidateTitleBar();
    self.activateTab(self.current_tab) catch {};
}

pub fn closeTab(self: *Window, mode: apprt.action.CloseTabMode) void {
    if (self.tabs.items.len == 0) return;
    switch (mode) {
        .this => self.closeTabAt(self.current_tab),
        .other => {
            var i = self.tabs.items.len;
            while (i > 0) {
                i -= 1;
                if (i == self.current_tab) continue;
                self.closeTabAt(i);
            }
        },
        .right => {
            var i = self.tabs.items.len;
            while (i > self.current_tab + 1) {
                i -= 1;
                self.closeTabAt(i);
            }
        },
    }
}

pub fn moveTab(self: *Window, amount: isize) bool {
    if (self.tabs.items.len <= 1 or amount == 0) return false;
    self.syncActiveTabFromWindow();
    const old_idx = self.current_tab;
    var desired: isize = @intCast(old_idx);
    desired = std.math.clamp(desired + amount, 0, @as(isize, @intCast(self.tabs.items.len - 1)));
    const new_idx: usize = @intCast(desired);
    if (new_idx == old_idx) return false;
    const moved = self.tabs.orderedRemove(old_idx);
    self.tabs.insert(self.app.alloc, new_idx, moved) catch return false;
    self.current_tab = new_idx;
    self.titlebar.hover = .none;
    self.invalidateTitleBar();
    self.activateTab(new_idx) catch {};
    return true;
}

pub fn gotoTab(self: *Window, target: apprt.action.GotoTab) bool {
    if (self.tabs.items.len == 0) return false;
    const idx: usize = switch (target) {
        .previous => (self.current_tab + self.tabs.items.len - 1) % self.tabs.items.len,
        .next => (self.current_tab + 1) % self.tabs.items.len,
        .last => self.tabs.items.len - 1,
        else => blk: {
            const raw: i32 = @intFromEnum(target);
            if (raw < 0) break :blk self.current_tab;
            break :blk @min(@as(usize, @intCast(raw)), self.tabs.items.len - 1);
        },
    };
    self.activateTab(idx) catch return false;
    return true;
}

pub fn focusSurface(self: *Window, surface: *Surface) void {
    const idx = self.findTabIndexForSurface(surface) orelse return;
    if (idx != self.current_tab) self.activateTab(idx) catch return;
    self.focused_surface = surface;
    if (self.current_tab < self.tabs.items.len) {
        self.tabs.items[self.current_tab].focused_surface = surface;
    }
}

pub fn initCoreSurface(self: *Window, surface: *Surface, opts: CreateOptions) !void {
    const alloc = self.app.alloc;
    const core = try alloc.create(CoreSurface);
    errdefer alloc.destroy(core);

    try self.app.core_app.addSurface(surface);
    errdefer self.app.core_app.deleteSurface(surface);

    var config = try apprt.surface.newConfig(self.app.core_app, self.app.config, .window);
    defer config.deinit();

    if (opts.command) |cmd| config.command = try cmd.clone(alloc);
    if (opts.working_directory) |wd| config.@"working-directory" = try wd.clone(alloc);
    if (opts.title) |title| config.title = try alloc.dupeZ(u8, title);

    try core.init(alloc, &config, self.app.core_app, self.app, surface);
    errdefer core.deinit();
    surface.core_surface = core;
}

pub fn applyConfiguredWindowSize(self: *Window) void {
    const cfg_w = if (self.app.config.@"window-width" > 0) self.app.config.@"window-width" else 80;
    const cfg_h = if (self.app.config.@"window-height" > 0) self.app.config.@"window-height" else 24;
    const hwnd = self.hwnd orelse return;
    const core = self.primary_surface.core_surface orelse return;

    const cell_width = core.size.cell.width;
    const cell_height = core.size.cell.height;
    if (cell_width == 0 or cell_height == 0) return;

    const w: i32 = @intCast(@max(10, cfg_w) * cell_width);
    const h: i32 = @intCast(@as(i32, @intCast(@max(4, cfg_h) * cell_height)) + self.titleBarHeight());

    var rect: RECT = .{ .left = 0, .top = 0, .right = w, .bottom = h };
    _ = sys.AdjustWindowRectEx(&rect, sys.WS_OVERLAPPEDWINDOW, 0, 0);
    // The custom frame has no caption; AdjustWindowRectEx includes one.
    var height = rect.bottom - rect.top;
    if (!self.quick_terminal) {
        const dpi = sys.GetDpiForWindow(hwnd);
        height -= sys.GetSystemMetricsForDpi(sys.SM_CYCAPTION, dpi);
    }
    _ = sys.SetWindowPos(hwnd, null, 0, 0, rect.right - rect.left, height, 0x0002 | 0x0004);
}

pub fn applyQuickTerminalLayout(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    var mi: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
    mi.cbSize = @sizeOf(sys.MONITORINFO);
    const monitor = sys.MonitorFromWindow(hwnd, 2);
    if (sys.GetMonitorInfoW(monitor, &mi) == 0) return;

    const dims: configpkg.Config.QuickTerminalSize.Dimensions = .{
        .width = @intCast(mi.rcWork.right - mi.rcWork.left),
        .height = @intCast(mi.rcWork.bottom - mi.rcWork.top),
    };
    const size = self.app.config.@"quick-terminal-size".calculate(
        self.app.config.@"quick-terminal-position",
        dims,
    );

    const width: i32 = @intCast(size.width);
    const height: i32 = @intCast(size.height);
    const work_w = mi.rcWork.right - mi.rcWork.left;
    const work_h = mi.rcWork.bottom - mi.rcWork.top;
    const origin: struct { x: i32, y: i32 } = switch (self.app.config.@"quick-terminal-position") {
        .top => .{ .x = mi.rcWork.left + @divTrunc(work_w - width, 2), .y = mi.rcWork.top },
        .bottom => .{ .x = mi.rcWork.left + @divTrunc(work_w - width, 2), .y = mi.rcWork.bottom - height },
        .left => .{ .x = mi.rcWork.left, .y = mi.rcWork.top + @divTrunc(work_h - height, 2) },
        .right => .{ .x = mi.rcWork.right - width, .y = mi.rcWork.top + @divTrunc(work_h - height, 2) },
        .center => .{
            .x = mi.rcWork.left + @divTrunc(work_w - width, 2),
            .y = mi.rcWork.top + @divTrunc(work_h - height, 2),
        },
    };

    _ = sys.SetWindowPos(hwnd, @ptrFromInt(@as(usize, @bitCast(@as(isize, -1)))), origin.x, origin.y, width, height, 0x0004);
}

pub fn relayout(self: *Window) void {
    const tree = &(self.tree orelse return);
    const hwnd = self.hwnd orelse return;
    var rect: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(hwnd, &rect) == 0) return;
    const tab_h = self.titleBarHeight();
    const bounds = SplitTree.Rect{
        .x = 0,
        .y = tab_h,
        .w = rect.right - rect.left,
        .h = rect.bottom - rect.top - tab_h,
    };
    tree.layout(bounds, relayoutCb);
    self.updateDividers(bounds);
    self.invalidateTitleBar();
}

fn relayoutCb(surface: *Surface, rect: SplitTree.Rect) void {
    surface.setLayoutRect(rect.x, rect.y, rect.w, rect.h);
    _ = sys.SetWindowPos(surface.hwnd, null, rect.x, rect.y, rect.w, rect.h, 0x0004);
}

pub fn newTab(self: *Window, opts: CreateOptions) !void {
    const insert_at = if (self.tabs.items.len == 0) 0 else self.current_tab + 1;
    _ = try self.insertTab(insert_at, opts, true);
}

pub fn newSplit(self: *Window, existing: *Surface, dir: apprt.action.SplitDirection) !void {
    const tree = &(self.tree orelse return error.NoTree);
    const alloc = self.app.alloc;

    const new_surface = try alloc.create(Surface);
    errdefer alloc.destroy(new_surface);
    new_surface.* = .{ .hwnd = undefined };

    try new_surface.init(self.hwnd.?, self.app);
    new_surface.window = self;
    errdefer new_surface.deinit();

    try self.initCoreSurface(new_surface, .none);
    errdefer {
        if (new_surface.core_surface) |core| {
            core.deinit();
            alloc.destroy(core);
        }
    }

    const split_dir: SplitTree.Direction = switch (dir) {
        .right, .left => .horizontal,
        .down, .up => .vertical,
    };
    const after = dir == .right or dir == .down;
    try tree.split(alloc, existing, new_surface, split_dir, after);

    self.focused_surface = new_surface;
    if (self.current_tab < self.tabs.items.len) {
        self.tabs.items[self.current_tab].focused_surface = new_surface;
    }
    _ = sys.SetFocus(new_surface.hwnd);
    self.relayout();
}

pub fn closeSurface(self: *Window, surface: *Surface) void {
    const tab_idx = self.findTabIndexForSurface(surface) orelse return;
    const use_active = tab_idx == self.current_tab and self.tree != null;
    var tree_copy = if (use_active) self.tree.? else self.tabs.items[tab_idx].tree;
    const tree = &tree_copy;
    const alloc = self.app.alloc;

    self.app.core_app.deleteSurface(surface);
    if (surface.core_surface) |core| {
        core.deinit();
        alloc.destroy(core);
        surface.core_surface = null;
    }
    surface.deinit();

    const result = tree.removeLeaf(alloc, surface);
    alloc.destroy(surface);

    if (result.empty) {
        self.closeEmptyTabAt(tab_idx);
        return;
    }

    if (use_active) {
        self.tree = tree_copy;
        self.focused_surface = result.focus;
        if (self.current_tab < self.tabs.items.len) {
            self.tabs.items[self.current_tab].focused_surface = result.focus;
        }
        if (result.focus) |focus| _ = sys.SetFocus(focus.hwnd);
        self.relayout();
    } else {
        self.tabs.items[tab_idx].tree = tree_copy;
        self.tabs.items[tab_idx].focused_surface = result.focus;
    }
}

pub fn gotoSplit(self: *Window, target: apprt.action.GotoSplit) void {
    const tree = &(self.tree orelse return);
    const current = self.focused_surface orelse return;

    var buf: [32]SplitTree.LeafRect = undefined;
    const hwnd = self.hwnd orelse return;
    var cr: RECT = std.mem.zeroes(RECT);
    if (sys.GetClientRect(hwnd, &cr) == 0) return;
    const bounds: SplitTree.Rect = .{
        .x = 0,
        .y = self.titleBarHeight(),
        .w = cr.right - cr.left,
        .h = cr.bottom - cr.top - self.titleBarHeight(),
    };
    const count = tree.collectLeafRects(bounds, &buf);
    if (count == 0) return;

    var current_idx: usize = 0;
    for (buf[0..count], 0..) |lr, i| {
        if (lr.surface == current) {
            current_idx = i;
            break;
        }
    }

    const next_idx: usize = switch (target) {
        .next => (current_idx + 1) % count,
        .previous => (current_idx + count - 1) % count,
        .up, .down, .left, .right => blk: {
            const cur = buf[current_idx].rect;
            const cx = cur.x + @divTrunc(cur.w, 2);
            const cy = cur.y + @divTrunc(cur.h, 2);
            var best: ?usize = null;
            var best_dist: i64 = std.math.maxInt(i64);
            for (buf[0..count], 0..) |lr, i| {
                if (i == current_idx) continue;
                const lx = lr.rect.x + @divTrunc(lr.rect.w, 2);
                const ly = lr.rect.y + @divTrunc(lr.rect.h, 2);
                const in_direction = switch (target) {
                    .up => ly < cy,
                    .down => ly > cy,
                    .left => lx < cx,
                    .right => lx > cx,
                    else => false,
                };
                if (!in_direction) continue;
                const dx: i64 = @as(i64, lx) - @as(i64, cx);
                const dy: i64 = @as(i64, ly) - @as(i64, cy);
                const dist = dx * dx + dy * dy;
                if (dist < best_dist) {
                    best_dist = dist;
                    best = i;
                }
            }
            break :blk best orelse return;
        },
    };

    const new_focus = buf[next_idx].surface;
    self.focused_surface = new_focus;
    if (self.current_tab < self.tabs.items.len) self.tabs.items[self.current_tab].focused_surface = new_focus;
    _ = sys.SetFocus(new_focus.hwnd);
}

pub fn equalizeSplits(self: *Window) void {
    const tree = &(self.tree orelse return);
    equalizeNode(tree.root);
    self.relayout();
}

fn equalizeNode(node: *SplitTree.Node) void {
    switch (node.*) {
        .leaf => {},
        .split => |*sp| {
            sp.ratio = 0.5;
            equalizeNode(sp.children[0]);
            equalizeNode(sp.children[1]);
        },
    }
}

pub fn resizeSplit(self: *Window, req: apprt.action.ResizeSplit) void {
    const tree = &(self.tree orelse return);
    const current = self.focused_surface orelse return;
    const want_horizontal = req.direction == .left or req.direction == .right;
    const grow = req.direction == .right or req.direction == .down;

    var path: [32]*SplitTree.Node = undefined;
    var path_len: usize = 0;
    if (!findPath(tree.root, current, &path, &path_len)) return;

    var i = path_len;
    while (i > 0) {
        i -= 1;
        const node = path[i];
        const sp = switch (node.*) {
            .split => |*v| v,
            .leaf => continue,
        };
        const matches = switch (sp.direction) {
            .horizontal => want_horizontal,
            .vertical => !want_horizontal,
        };
        if (!matches) continue;

        const first_contains = containsLeaf(sp.children[0], current);
        const delta: f32 = @as(f32, @floatFromInt(req.amount)) / 400.0;
        var new_ratio = sp.ratio;
        if (first_contains) {
            new_ratio += if (grow) delta else -delta;
        } else {
            new_ratio += if (grow) -delta else delta;
        }
        sp.ratio = std.math.clamp(new_ratio, 0.1, 0.9);
        self.relayout();
        return;
    }
}

fn findPath(node: *SplitTree.Node, target: *Surface, path: []*SplitTree.Node, len: *usize) bool {
    if (len.* >= path.len) return false;
    path[len.*] = node;
    len.* += 1;
    switch (node.*) {
        .leaf => |s| if (s == target) return true,
        .split => |sp| {
            if (findPath(sp.children[0], target, path, len)) return true;
            if (findPath(sp.children[1], target, path, len)) return true;
        },
    }
    len.* -= 1;
    return false;
}

fn containsLeaf(node: *SplitTree.Node, target: *Surface) bool {
    return switch (node.*) {
        .leaf => |s| s == target,
        .split => |sp| containsLeaf(sp.children[0], target) or containsLeaf(sp.children[1], target),
    };
}

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
            // open. InvalidateRect only queues a WM_PAINT, which runs
            // after the default proc has stored the new text.
            self.invalidateTitleBar();
            return null;
        },
        sys.WM_ERASEBKGND => return 1,
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
        WM_CAPTURECHANGED => {
            // Capture stolen mid-press (e.g. a system action between
            // button down and up): reset the titlebar press state.
            if (!self.titlebar.pressed.eql(.none)) {
                self.titlebar.pressed = .none;
                self.invalidateTitleBar();
            }
            return null;
        },
        else => {},
    }
    return null;
}

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

pub fn toggleFullscreen(self: *Window) void {
    const hwnd = self.hwnd orelse return;
    if (self.fullscreen.active) {
        _ = sys.SetWindowLongW(hwnd, sys.GWL_STYLE, self.fullscreen.style);
        _ = sys.SetWindowLongW(hwnd, sys.GWL_EXSTYLE, self.fullscreen.ex_style);
        // Must be set before SetWindowPos: WM_NCCALCSIZE reads this flag.
        self.fullscreen.active = false;
        _ = sys.SetWindowPos(
            hwnd,
            null,
            self.fullscreen.rect.left,
            self.fullscreen.rect.top,
            self.fullscreen.rect.right - self.fullscreen.rect.left,
            self.fullscreen.rect.bottom - self.fullscreen.rect.top,
            0x0020 | 0x0004,
        );
    } else {
        self.fullscreen.style = @intCast(sys.GetWindowLongW(hwnd, sys.GWL_STYLE));
        self.fullscreen.ex_style = @intCast(sys.GetWindowLongW(hwnd, sys.GWL_EXSTYLE));
        _ = sys.GetWindowRect(hwnd, &self.fullscreen.rect);

        var mi: sys.MONITORINFO = std.mem.zeroes(sys.MONITORINFO);
        mi.cbSize = @sizeOf(sys.MONITORINFO);
        const monitor = sys.MonitorFromWindow(hwnd, 2);
        if (sys.GetMonitorInfoW(monitor, &mi) == 0) return;

        const new_style = self.fullscreen.style & ~@as(i32, @bitCast(@as(u32, sys.WS_OVERLAPPEDWINDOW)));
        _ = sys.SetWindowLongW(hwnd, sys.GWL_STYLE, new_style);
        // Must be set before SetWindowPos: WM_NCCALCSIZE reads this flag.
        self.fullscreen.active = true;
        _ = sys.SetWindowPos(
            hwnd,
            null,
            mi.rcMonitor.left,
            mi.rcMonitor.top,
            mi.rcMonitor.right - mi.rcMonitor.left,
            mi.rcMonitor.bottom - mi.rcMonitor.top,
            0x0020 | 0x0004,
        );
    }
}
