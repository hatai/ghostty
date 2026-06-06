# win32: コマンドパレット リデザイン

日付: 2026-06-06
ステータス: 承認済み(ブラウザモックアップ B 案で視覚確認済み)

## 目的

Ctrl+Shift+P のコマンドパレットを現代化する。現状はネイティブ EDIT + LISTBOX に固定ダーク色を当てただけ(四角い枠線、システム標準の選択色、テーマ非追従)。カスタムタイトルバーと同じトーンの、テーマ追従なモダンデザインに刷新する。

## 決定事項(ユーザー確認済み)

| 項目 | 決定 |
|---|---|
| ビジュアル | 角丸ピル選択(Fluent / PowerToys Run 風、モックアップ B) |
| スコープ | 見た目刷新 + キーバインド表示 + ファジー検索 |
| 技術方式 | オーナードロー LISTBOX + ネイティブ EDIT 維持(IME 保全) |
| 対象外 | アクション名の 2 行表示、アイコン、最近使ったコマンドの優先表示 |

## ビジュアル仕様

- **ポップアップ**: `WS_BORDER` 廃止。色は `TitleBar.Palette`(config の background/foreground から導出)を共有。Win11 では `DWMWA_WINDOW_CORNER_PREFERENCE = DWMWCP_ROUND` で角丸、`DWMWA_BORDER_COLOR` でテーマ色の枠線
- **検索行**: 上部 44px(DPI スケール)。ボーダーレス EDIT(背景 = パネル色、文字 = fg)、下に 1px 区切り線
- **リスト行**: 高さ 36px。選択行は全角丸 8px のピル(`blend(bg, accent)` 系の面色)。タイトル左寄せ、キーバインド右寄せ
- **マッチハイライト**: ファジーマッチした文字をアクセント色 + 太字相当で強調
- **キーバインド**: キーごとに小さな角丸ボックス(キーキャップ風)、文字は控えめな色
- **下部ヒント行**: 「↑↓ 選択 / Enter 実行 / Esc 閉じる」を小さく表示
- **0 件時**: リスト中央に「No matching commands」

## 機能仕様

### ファジー検索
- subsequence マッチ: クエリ各文字が順に title または `@tagName(action)` に現れればマッチ(ASCII case-insensitive)
- スコア: 連続一致ボーナス + 単語頭(空白/`_` 直後)ボーナス − ギャップペナルティ。スコア降順で表示
- マッチ位置(title 内インデックス)を保持し描画でハイライト。action 名のみのマッチはハイライトなし
- 空クエリ: 全コマンドを定義順で表示

### キーバインド表示
- `app.config.keybind.set.getTrigger(cmd.action)` で先頭の `Trigger` を取得(なければ非表示)
- 整形: mods を Ctrl → Alt → Shift → Win の順。キー名は Trigger の key に応じて整形: `.physical/.unicode` の値から `key_a→A`、`digit_1→1`、`enter→Enter`、`f11→F11` のように enum 名/コードポイントを表示名へ変換する小関数を実装(マップにない名前は先頭大文字化で表示)。`+` 区切りでキーキャップ描画

## 実装構成

- 変更は `src/apprt/win32/CommandPalette.zig` 中心。新ファイルなし
- `TitleBar.zig` から `Rgb`/`Palette` を import。全角丸塗り用ヘルパー `fillRounded`(fillRoundedTop の全角丸版)を TitleBar.zig に追加して共有
- LISTBOX スタイルに `LBS_OWNERDRAWFIXED` を追加し、親 wndProc で `WM_MEASUREITEM`(行高)/`WM_DRAWITEM`(行描画)を処理
- 行描画: GDI(ClearType テキスト、`DrawTextW`)+ GDI+(ピル/キーキャップの角丸)。ダブルバッファは LISTBOX 描画では不要(行単位描画)
- `filtered` を `ArrayListUnmanaged(Match)` に変更: `Match = struct { cmd_idx: usize, score: i32, positions: std.StaticBitSet(64) }`(title 先頭 64 文字のマッチ位置。空 = ハイライトなし)
- スクロールバー: ネイティブのまま。`SetWindowTheme(list_hwnd, L"DarkMode_Explorer", null)`(uxtheme)でダーク化を試み、失敗しても致命でない
- EDIT のボーダーレス化: スタイルから WS_BORDER を外し、WM_CTLCOLOREDIT は現行どおり(色は Palette 由来に変更)
- 既存の固定色 `BG_COLOR`/`FG_COLOR` 定数と専用 `ui_font` グローバルは Palette/DPI 対応のフォント生成に置換

## エッジケース

- **IME**: EDIT はネイティブ維持なので日本語変換はそのまま動作。EN_CHANGE → refilter も現行どおり
- **DPI**: 全寸法 `GetDpiForWindow(popup)` でスケール。WM_MEASUREITEM も DPI 反映
- **ライトテーマ**: Palette 導出のため自動対応
- **Win10**: DWMWA_WINDOW_CORNER_PREFERENCE が無視される(角ばったまま)— 許容
- **長いタイトル**: DT_END_ELLIPSIS で省略。キーバインド領域を先に確保

## テスト

- WSL: `zig build -Dtarget=x86_64-windows-gnu` で型チェック。ファジースコアラーは pure 関数として `test` ブロックを付ける
- Windows 実機: 開閉(Ctrl+Shift+P / Esc / フォーカス喪失)、絞り込み(ファジー: "nt" → New Tab がヒット)、↑↓ / Enter / ダブルクリック実行、キーバインド表示の正しさ、IME で日本語入力→確定→絞り込み、DPI 150%、ライトテーマ

## 参考(現状コード)

- `src/apprt/win32/CommandPalette.zig`(全 474 行): open/close/filter/executeSelected/wndProc/preTranslateMessage
- 固定色: L362-363(BG_COLOR/FG_COLOR)、WM_CTLCOLOR 処理: L395-405
- キーバインド逆引き: `src/input/Binding.zig` L2647 `Set.getTrigger`(GTK 利用例: `src/apprt/gtk/class/command_palette.zig` L674)
- 色導出の共有元: `src/apprt/win32/TitleBar.zig`(Rgb/Palette/fillRoundedTop)
