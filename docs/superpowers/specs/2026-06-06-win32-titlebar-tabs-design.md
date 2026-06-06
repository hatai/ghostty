# win32: カスタムタイトルバー & タブ統合デザイン

日付: 2026-06-06
ステータス: 承認済み(ブラウザモックアップで視覚確認済み)

## 目的

win32 apprt の見た目を現代化する。現状は「白いネイティブタイトルバー + Windows 95 風 SysTabControl32」でダークなターミナルと不調和。タブをタイトルバーに統合した Windows Terminal 風の外観に置き換え、縦スペースも 30px 節約する。

## 決定事項(ユーザー確認済み)

| 項目 | 決定 |
|---|---|
| 方向性 | タブ・イン・タイトルバー(完全カスタムフレーム) |
| タブ形状 | 角丸トップ(半径 8px、Windows Terminal 風) |
| 色 | テーマ追従(設定の background / foreground から導出) |
| タブ 1 つ時 | タブ形状を描かずウィンドウタイトル文字のみ |
| インタラクション | 基本セットのみ(ホバー ✕ / + ボタン / ホバーハイライト / ミドルクリック閉じ) |
| スコープ外 | ドラッグ並べ替え、Win11 スナップレイアウト対応、ツールチップ |

## アーキテクチャ

### コンポーネント構成

1. **フレームカスタム化** — `src/apprt/win32/Window.zig`
   - `WM_NCCALCSIZE`: 標準タイトルバーを除去(リサイズボーダーは維持)。最大化時は 8px のはみ出しを補正
   - `WM_NCHITTEST`: 上端リサイズ帯 / タブバー空き領域 = `HTCAPTION` / キャプションボタン / タブ領域(クライアント扱い)を判定
   - `DwmExtendFrameIntoClientArea`(上 1px): Win11 の影と角丸を維持
   - `DwmSetWindowAttribute(DWMWA_USE_IMMERSIVE_DARK_MODE)`: システムメニュー等の整合
   - `SysTabControl32`(`tab_hwnd`)は廃止。タブ管理 API 呼び出し(TCM_*)を TitleBar モジュール呼び出しに置換

2. **タイトルバー描画モジュール** — 新規 `src/apprt/win32/TitleBar.zig`
   - HWND を持たない純粋モジュール。Window.zig が `WM_PAINT` / マウスイベントを委譲
   - 描画: バー背景、タブ(角丸トップ)、タブ番号+タイトル(省略付き)、✕、+ ボタン、ウィンドウタイトル(1 タブ時)、キャプションボタン ─ □ ✕
   - ヒットテスト API: 座標 → {タブ index, タブ✕, +, 最小化, 最大化, 閉じる, ドラッグ領域, なし}
   - ホバー状態管理(`WM_MOUSEMOVE` + `TrackMouseEvent`/`WM_MOUSELEAVE`)

### 描画技術

- 図形: **GDI+ flat C API**(GdipFillPath / GdipCreatePath 等、アンチエイリアス有効)。起動時に `GdiplusStartup`
- テキスト: GDI `TextOutW`(ClearType、既存 Segoe UI フォント流用)
- ダブルバッファ(メモリ DC + BitBlt)でちらつき防止
- Direct2D は COM 実装コストが高いため不採用。既存 GDI(ディバイダー、プログレス)はそのまま

### カラーパレット導出(テーマ追従)

設定の `background`(bg)/ `foreground`(fg)から計算:

| 要素 | 導出 |
|---|---|
| バー背景 | bg を 25% 暗く |
| アクティブタブ | bg と同色(ターミナル面とシームレス) |
| ホバータブ | バー背景を 8% 明るく |
| アクティブ文字 | fg |
| 非アクティブ文字 | fg を bg へ 50% ブレンド |
| 非アクティブウィンドウ時 | 文字をさらに減衰 |
| ✕ ホバー(キャプション) | #E81123(Windows 標準) |

設定リロード時に再計算して `InvalidateRect`。

### レイアウト定数(96 DPI 基準、DPI スケール対象)

- バー高さ: 38px(うち上 6px はタブ上余白 = ドラッグ領域)
  - バーはタイトルバーを兼ねるため**常時表示**(フルスクリーン時を除く)。旧 `updateTabVisibility`(1 タブ時に隠す)と `tabClientHeight` の 0/30 切替は廃止し、常に 38px をサーフェス領域からオフセット
- タブ幅: 動的、最小 110px / 最大 220px
- 角丸: 上のみ半径 8px
- キャプションボタン: 各 46x38px
- 左端: Ghostty アイコン(余白 12px)

## エッジケース

- **最大化**: NCCALCSIZE 補正、タブ上余白はタブクリック扱い
- **非アクティブ**: WM_ACTIVATE で再描画、文字減衰
- **フルスクリーン**: バーごと非表示(既存 borderless 処理と整合)
- **DPI 変更**: WM_DPICHANGED で寸法・フォント再計算(既存処理に追従)
- **タブ多数**: 最小幅 110px を下回る場合はタイトル省略を強める(横スクロールはスコープ外)

## テスト

- WSL: `zig build -Dtarget=x86_64-windows-gnu` で型チェック
- Windows 実機: タブ作成/切替/閉じる(✕・ミドルクリック)、ドラッグ移動、リサイズ、最大化/復元、スナップ(Win+矢印)、DPI 150% で確認
- ライトテーマ(背景明色)でパレットが破綻しないこと

## 参考(現状コード)

- ウィンドウ生成: `src/apprt/win32/Window.zig:198-240`(WS_OVERLAPPEDWINDOW)
- 旧タブ生成: `Window.zig:242-283`(SysTabControl32、TAB_HEIGHT=30、L50)
- レイアウト: `Window.zig:919-937`(relayout、タブ高さ分オフセット)
- タブ操作: TCM_INSERTITEMW(L659)/ TCM_DELETEITEM(L720)/ TCM_SETCURSEL / TCN_SELCHANGE(L1167)
- ディバイダー GDI 描画: `Window.zig:427-450`
