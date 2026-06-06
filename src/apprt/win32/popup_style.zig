//! Shared visual style for win32 popup dialogs (prompt dialog, search
//! panel). Encapsulates the theme-derived resources (palette, fonts,
//! brushes) plus the common chrome/drawing helpers so every popup
//! matches the command palette's design language.
//!
//! Owns no HWND. Each dialog creates a PopupTheme in open() and
//! deinits it in close(); deinit is idempotent so errdefer + close
//! can both call it safely.
const std = @import("std");
const sys = @import("sys.zig");
const TitleBar = @import("TitleBar.zig");
const configpkg = @import("../../config.zig");

extern "gdi32" fn SetBkColor(hdc: ?*anyopaque, color: u32) callconv(.winapi) u32;

/// One keyboard hint: a keycap chip ("Enter") plus its label ("Save").
pub const Hint = struct {
    key: []const u8,
    label: []const u8,
};

pub const PopupTheme = struct {
    pal: TitleBar.Palette,
    dpi: u32 = 96,
    font_main: ?*anyopaque = null,
    font_small: ?*anyopaque = null,
    /// Panel background (pal.bar_bg) for WM_ERASEBKGND.
    bg_brush: ?*anyopaque = null,
    /// Input-field background (pal.active_tab) for WM_CTLCOLOREDIT.
    input_brush: ?*anyopaque = null,

    pub fn init(parent: sys.HWND, config: *const configpkg.Config) PopupTheme {
        const bg = config.background;
        const fg = config.foreground;
        const pal = TitleBar.Palette.derive(
            .{ .r = bg.r, .g = bg.g, .b = bg.b },
            .{ .r = fg.r, .g = fg.g, .b = fg.b },
        );
        var self: PopupTheme = .{
            .pal = pal,
            .dpi = sys.GetDpiForWindow(parent),
        };
        self.bg_brush = sys.CreateSolidBrush(pal.bar_bg.colorref());
        self.input_brush = sys.CreateSolidBrush(pal.active_tab.colorref());
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
        return self;
    }

    /// Idempotent: safe to call from both errdefer and close().
    pub fn deinit(self: *PopupTheme) void {
        if (self.bg_brush) |b| _ = sys.DeleteObject(b);
        if (self.input_brush) |b| _ = sys.DeleteObject(b);
        if (self.font_main) |f| _ = sys.DeleteObject(f);
        if (self.font_small) |f| _ = sys.DeleteObject(f);
        self.bg_brush = null;
        self.input_brush = null;
        self.font_main = null;
        self.font_small = null;
    }

    /// Scale a 96-dpi design value to the dialog's DPI.
    pub fn s(self: *const PopupTheme, v: i32) i32 {
        return @divTrunc(v * @as(i32, @intCast(self.dpi)), 96);
    }

    /// Win11 rounded corners + theme border color (no-ops on Win10).
    pub fn applyChrome(self: *const PopupTheme, hwnd: sys.HWND) void {
        const corner: i32 = sys.DWMWCP_ROUND;
        _ = sys.DwmSetWindowAttribute(
            hwnd,
            sys.DWMWA_WINDOW_CORNER_PREFERENCE,
            &corner,
            @sizeOf(i32),
        );
        const border_color: u32 = self.pal.outline.colorref();
        _ = sys.DwmSetWindowAttribute(
            hwnd,
            sys.DWMWA_BORDER_COLOR,
            &border_color,
            @sizeOf(u32),
        );
    }

    /// WM_CTLCOLOREDIT: the EDIT sits inside the rounded input box, so
    /// its background is the input fill, not the panel background.
    /// Returns the brush to be returned (bit-cast) from the wndProc.
    pub fn ctlColorInput(self: *const PopupTheme, hdc: ?*anyopaque) ?*anyopaque {
        _ = sys.SetTextColor(hdc, self.pal.text_active.colorref());
        _ = SetBkColor(hdc, self.pal.active_tab.colorref());
        return self.input_brush;
    }

    /// WM_ERASEBKGND: fill the whole client area with the panel color.
    pub fn eraseBkgnd(self: *const PopupTheme, hwnd: sys.HWND, wparam: sys.WPARAM) sys.LRESULT {
        const brush = self.bg_brush orelse return 0;
        var rc: sys.RECT = std.mem.zeroes(sys.RECT);
        _ = sys.GetClientRect(hwnd, &rc);
        const hdc: ?*anyopaque = @ptrFromInt(wparam);
        _ = sys.FillRect(hdc, &rc, brush);
        return 1;
    }

    /// Rounded input field: outline ring + inner fill. The borderless
    /// EDIT control is placed inside with the same background color so
    /// the square control blends into the rounded box.
    pub fn drawInputBox(self: *const PopupTheme, hdc: sys.HDC, rect: sys.RECT) void {
        TitleBar.fillRoundedRect(hdc, self.pal.outline.argb(), rect, self.s(6));
        const inner: sys.RECT = .{
            .left = rect.left + 1,
            .top = rect.top + 1,
            .right = rect.right - 1,
            .bottom = rect.bottom - 1,
        };
        TitleBar.fillRoundedRect(hdc, self.pal.active_tab.argb(), inner, self.s(6));
    }

    /// Draw a UTF-8 text label. Caller selects the font beforehand.
    pub fn drawLabel(
        self: *const PopupTheme,
        hdc: sys.HDC,
        rect: sys.RECT,
        text: []const u8,
        color: u32,
        flags: sys.UINT,
    ) void {
        _ = self;
        var wbuf: [256]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return;
        if (wlen == 0) return;
        _ = sys.SetBkMode(hdc, sys.TRANSPARENT);
        _ = sys.SetTextColor(hdc, color);
        var r = rect;
        _ = sys.DrawTextW(hdc, &wbuf, @intCast(wlen), &r, flags);
    }

    const chip_pad_du = 6; // horizontal padding inside a keycap chip
    const gap_in_du = 6; // chip -> its label
    const gap_out_du = 14; // hint -> next hint

    /// Total pixel width drawHints would use (for right alignment).
    /// Measures with font_small selected temporarily.
    pub fn measureHints(self: *const PopupTheme, hdc: sys.HDC, hints: []const Hint) i32 {
        const old_font = sys.SelectObject(hdc, self.font_small);
        defer _ = sys.SelectObject(hdc, old_font);
        var total: i32 = 0;
        for (hints, 0..) |hint, i| {
            total += self.textWidth(hdc, hint.key) + 2 * self.s(chip_pad_du);
            total += self.s(gap_in_du);
            total += self.textWidth(hdc, hint.label);
            if (i + 1 < hints.len) total += self.s(gap_out_du);
        }
        return total;
    }

    /// Draw "[Enter] Save   [Esc] Cancel" style hints, left-aligned
    /// starting at rect.left, vertically centered in rect.
    pub fn drawHints(self: *const PopupTheme, hdc: sys.HDC, rect: sys.RECT, hints: []const Hint) void {
        _ = sys.SetBkMode(hdc, sys.TRANSPARENT);
        const old_font = sys.SelectObject(hdc, self.font_small);
        defer _ = sys.SelectObject(hdc, old_font);

        const cap_h = self.s(16);
        const cy = @divTrunc(rect.top + rect.bottom - cap_h, 2);
        var x = rect.left;
        for (hints) |hint| {
            const key_w = self.textWidth(hdc, hint.key);
            const cap: sys.RECT = .{
                .left = x,
                .top = cy,
                .right = x + key_w + 2 * self.s(chip_pad_du),
                .bottom = cy + cap_h,
            };
            TitleBar.fillRoundedRect(hdc, self.pal.surface.argb(), cap, self.s(4));
            self.drawLabel(
                hdc,
                cap,
                hint.key,
                self.pal.text_inactive.colorref(),
                sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_CENTER | sys.DT_NOPREFIX,
            );
            x = cap.right + self.s(gap_in_du);

            const label_w = self.textWidth(hdc, hint.label);
            const lrc: sys.RECT = .{
                .left = x,
                .top = rect.top,
                .right = x + label_w,
                .bottom = rect.bottom,
            };
            self.drawLabel(
                hdc,
                lrc,
                hint.label,
                self.pal.text_inactive.colorref(),
                sys.DT_SINGLELINE | sys.DT_VCENTER | sys.DT_NOPREFIX,
            );
            x = lrc.right + self.s(gap_out_du);
        }
    }

    fn textWidth(self: *const PopupTheme, hdc: sys.HDC, text: []const u8) i32 {
        _ = self;
        var wbuf: [64]u16 = undefined;
        const wlen = std.unicode.utf8ToUtf16Le(&wbuf, text) catch return 0;
        if (wlen == 0) return 0;
        var size: sys.SIZE = .{ .cx = 0, .cy = 0 };
        _ = sys.GetTextExtentPoint32W(hdc, &wbuf, @intCast(wlen), &size);
        return size.cx;
    }
};
