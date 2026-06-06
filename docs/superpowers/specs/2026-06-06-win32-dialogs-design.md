# win32: ダイアログ刷新(タイトル編集 + 検索パネル)

日付: 2026-06-06
ステータス: 承認済み(ブラウザモックアップ B 案で視覚確認済み)

## 目的

コマンドパレット刷新後も残っている旧スタイルのポップアップ 2 つ — タイトル編集ダイアログ(PromptDialog)と検索パネル(SearchPanel)— を、パレットと同じデザイン言語(テーマ追従色・角丸・ボーダーレス・キーヒント)に統一する。現状は `WS_BORDER` の四角いポップアップにテーマ未対応のネイティブ EDIT/BUTTON/STATIC(白背景・灰ボタン)が乗っている。

## 決定事項(ユーザー確認済み)

| 項目 | 決定 |
|---|---|
| 対象 | PromptDialog と SearchPanel の両方 |
| 操作 UI | キーヒントのみ(ボタン全廃、モックアップ B) |
| 技術方式 | 共有スタイルモジュール `popup_style.zig` を新設し両者で使用 |
| CommandPalette | 今回は触らない(共通化は将来の任意リファクタ) |

## ビジュアル仕様(共通)

- `WS_BORDER` 廃止。DWM で角丸(`DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND`)+ テーマ色枠線(`DWMWA_BORDER_COLOR = pal.outline`)
- 色は `TitleBar.Palette`(config の background/foreground から導出、リロード追従は次回 open 時)
- パネル背景 = `pal.bar_bg`、入力ボックス = 角丸 6px(外周 `pal.outline`、内側 `pal.active_tab`)、EDIT はボーダーレスで内側に配置(背景同色で角丸枠と一体に見せる)
- フォント: Segoe UI、メイン -15 / スモール -11(DPI スケール、per-open 生成)
- キーヒント: キーキャップ風チップ(`pal.surface` 地 + `pal.text_inactive` 文字)+ 説明テキスト
- 全寸法 DPI スケール(96dpi 基準値を `GetDpiForWindow(parent)` で換算)

## PromptDialog(タイトル編集)

レイアウト(96dpi 基準、幅 420 / 高さ 自動 ≒ 110):
1. ヘッダ行 34px: モード名(「Set Title」/「Set Tab Title」)を `pal.text_active` で
2. 入力ボックス 36px(左右マージン 14px)
3. ヒント行 30px: `Enter` Save / `Esc` Cancel

機能変更:
- OK/Cancel ボタンと WM_COMMAND の OK_ID/CANCEL_ID 処理を削除
- Enter(accept)/Esc(close)は既存の `preTranslateMessage` がそのまま担う
- フォーカス喪失で閉じる(WM_ACTIVATE)は現行どおり

## SearchPanel(検索)

レイアウト(96dpi 基準、幅 460 / 高さ 自動 ≒ 104):
1. 入力ボックス 36px(上マージン 12px)
2. 下段 28px: 左にステータス(`3 / 12` 形式、`pal.text_inactive`)、右にヒント(`Enter` Next / `Shift+Enter` Prev / `Esc` Close)

機能変更:
- Prev/Next/Close ボタンと STATIC ステータスコントロールを削除(WM_COMMAND の PREV/NEXT/CLOSE_ID 処理も削除)
- ステータスは親の WM_PAINT で描画。`updateStatus` は文字列保持(`status_buf`)+ `InvalidateRect` に変更
- **キー操作追加**: `preTranslateMessage` で Enter → `navigate(.next)`、Shift+Enter → `navigate(.previous)`(`sys.GetKeyState(VK_SHIFT) < 0` で判定)
- インクリメンタル検索(EN_CHANGE → performSearch)、`setSearchTotal`/`setSearchSelected` の外部 API、`end_search` 通知付き close は現行どおり

## 共有モジュール `src/apprt/win32/popup_style.zig`

HWND を持たない描画/テーマ補助。TitleBar.zig の `Palette`/`Rgb`/`fillRoundedRect` を再利用する。

```
pub const PopupTheme = struct {
    pal: TitleBar.Palette,
    dpi: u32,
    font_main: ?*anyopaque,   // Segoe UI -s(15)
    font_small: ?*anyopaque,  // Segoe UI -s(11)
    bg_brush: ?*anyopaque,    // pal.bar_bg(パネル背景・WM_ERASEBKGND 用)
    input_brush: ?*anyopaque, // pal.active_tab(EDIT の WM_CTLCOLOREDIT 用)

    pub fn init(parent: HWND, config: *const Config) PopupTheme
    pub fn deinit(self: *PopupTheme)                   // 冪等(二重呼び出し安全)
    pub fn s(self, v: i32) i32
    pub fn applyChrome(self, hwnd: HWND) void          // DWM 角丸 + 枠色
    pub fn ctlColorInput(self, hdc) ?HBRUSH            // EDIT 用: 文字 fg / 背景 active_tab
    pub fn eraseBkgnd(self, hwnd, wparam) LRESULT      // 背景塗り → 1
    pub fn drawInputBox(self, hdc, rect) void          // 角丸 outline + 内側 active_tab
    pub fn drawLabel(self, hdc, rect, utf8, color, flags) void
    pub fn measureHints(self, hdc, hints) i32          // 右寄せ用の合計幅
    pub fn drawHints(self, hdc, rect, hints: []const Hint) void
};
pub const Hint = struct { key: []const u8, label: []const u8 };
```

- `drawHints` はチップ(`fillRoundedRect`、`pal.surface`)+ キー名(font_small)+ 説明文を左から並べる
- EDIT の配置は各ダイアログ側の責務(drawInputBox の内側に s(8) インセットで置く)
- リソースは per-open: 各ダイアログの open() で `PopupTheme.init`、close() で `deinit`。open() の errdefer でも deinit(パレットで踏んだリーク轍の回避)

## ライフサイクル安全性

- `App.closeWindow` に、command_palette と同様の `target_window` クリアを prompt_dialog / search_panel にも追加(`*_initialized` ガード + close() 呼び出し + null 代入)— ウィンドウ破棄後の参照(UAF)防止
- 両ダイアログの `deinit()` は `close()` 経由でリソース解放(SearchPanel は `close(false)` — 終了時に end_search 通知は不要)

## エッジケース

- IME: EDIT はネイティブ維持。日本語タイトル・日本語検索は現行どおり動作
- Win10: DWM 角丸は無視され四角(許容)
- ライトテーマ: Palette 導出で自動対応
- 検索ステータスが未確定(total == null): ステータス欄は空表示

## テスト

- WSL: `zig ast-check` 各ファイル + `zig build -Dtarget=x86_64-windows-gnu`(popup_style.zig は両ダイアログが参照するため型チェックされる)
- Windows 実機: タイトル編集(表示・Enter 保存・Esc 取消・フォーカス喪失クローズ・IME・初期値表示)、検索(表示・インクリメンタル・Enter/Shift+Enter ナビ・ステータス更新・Esc で end_search)、DPI 150%、ライトテーマ

## 参考(現状コード)

- `src/apprt/win32/PromptDialog.zig`(211 行): open L70-114(BUTTON 2 個)、accept L125-136、preTranslateMessage L138-153(Enter/Esc 済み)、wndProc L155-186
- `src/apprt/win32/SearchPanel.zig`(257 行): open L72-115(BUTTON 3 個 + STATIC)、updateStatus L163-176、navigate L196-199、wndProc L200-231
- 流用元: `src/apprt/win32/TitleBar.zig`(Palette/Rgb/fillRoundedRect/blend)、`src/apprt/win32/CommandPalette.zig`(同パターンの実装例)
- UAF 対策の先例: `src/apprt/win32/App.zig` closeWindow の command_palette ブロック
