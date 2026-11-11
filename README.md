# UsageBar

Claude Code と Codex CLI の使用状況を、Mac のメニューバーに表示するアプリです。
外部とは通信せず、手元のログだけを読みます。

<img src="docs/screenshot.png" alt="メニューバーの UsageBar を開いたところ。Claude の 5 時間枠と週間枠、Codex の週間枠の使用率、今日と直近 5 時間のトークン数、過去 7 日の推移が並ぶ" width="391">

- メニューバーには 2 本のメーターと数値が並びます。上が Claude、下が Codex で、それぞれ最も上限に近い枠の使用率です。
- クリックすると、枠ごとの使用率とリセットまでの残り時間、今日と直近 5 時間のトークン数、過去 7 日の推移、モデル別の内訳を表示します。
- ログが書き足されると、FSEvents で検知して 1 秒以内に表示を更新します。取りこぼしに備えて、5 分ごとにフォルダ全体も見直します。

## 値の取得元

| 表示 | 取得元 | 仕組み |
|---|---|---|
| Codex の使用率（5 時間枠・週間枠） | `~/.codex/sessions/**/rollout-*.jsonl` | Codex CLI が応答ごとに書く `token_count` イベントの `rate_limits` |
| Codex のトークン数 | 同上 | 同じイベントの `last_token_usage`。累計の `total_token_usage` が変わったときだけ数える |
| Claude の使用率（5 時間枠・週間枠） | `~/.claude/usagebar/claude-rate-limits.json` | Claude Code がステータスラインのコマンドに渡す `rate_limits` を、中継コマンド `usagebar-bridge` が数値だけ書き出す |
| Claude のトークン数 | `~/.claude/projects/**/*.jsonl` | 応答ごとの `message.usage`。`message.id` と `requestId` で重複を除く |

どちらも、各 CLI が手元にすでに書いている情報です。UsageBar が API を呼ぶことはありません。

## セキュリティの方針

**通信しないことを OS に強制させる。** アプリ本体は App Sandbox の中で動き、通信の権限（`com.apple.security.network.client` / `network.server`）を持ちません。アプリのコードに不具合や混入があっても、DNS を含めて OS が通信を遮断します。

**読める場所を絞る。** ファイルの読み取りは、次の 4 か所だけを読み取り専用で許可しています（`Resources/UsageBar.entitlements`）。

- `~/.claude/projects/`
- `~/.claude/usagebar/`
- `~/.codex/sessions/`
- `~/.codex/archived_sessions/`

`~/.codex/auth.json`、`~/.claude/.credentials.json`、Keychain など認証情報のある場所は読めません。CodexBar などが使う「OAuth トークンを読んで使用量の API を呼ぶ」方式は、認証情報を扱うことになるため採っていません。

**ログの本文は扱わない。** 解析用の型にはトークン数・モデル名・時刻・利用上限の項目だけを定義し、会話本文やツールの入出力は読み捨てます。中継コマンドが書くファイルにも、使用率とリセット時刻の数値しか入りません。

**壊れた入力や細工された入力に備える。**

- ログとスナップショットはシンボリックリンクをたどらずに開き（`O_NOFOLLOW`）、通常のファイル以外は読みません。
- 1 行が 32MB を超える行は捨てます。スナップショットは 64KB を超えたら読みません。標準入力も 4MB までしか読みません。
- トークン数は 1 回あたり 1 兆までに抑え、合計は Int64 の上限で止めます（あふれてアプリが止まらないように）。
- 使用率は 0〜1000% に収めます。時刻は 2000〜2200 年の範囲外を捨て、2/31 のような存在しない日付も捨てます。
- 中継コマンドは書き込み先のディレクトリが自分の所有でなければ書きません。ファイルは権限 600 で作り、rename で置き換えます。

**Claude Code の設定を壊さない。** `install` / `uninstall` は次を守ります。

- 書き換える前に `settings.json` のバックアップを残す
- 読み込んでから書き込むまでの間にファイルが変わったら、書かずに止める
- シンボリックリンクならリンク先を書き換える。元の権限も保つ
- 自分が登録した形（`usagebar-bridge` の絶対パスだけ）以外の `statusLine` には触れない。`my.sh | usagebar-bridge` のように自分で組み立てたコマンドは、上書きも削除もしない
- ビルド用のフォルダ（`.build/`、`build.noindex/`）にある `usagebar-bridge` は登録しない。次のビルドで消えるため

**依存を増やさない。** 外部パッケージは使わず、Apple のフレームワークだけで作っています。自動アップデートや利用状況の送信もありません。

### 確かめ方

```bash
scripts/verify-security.sh ~/Applications/UsageBar.app       # 起動中のアプリを検査
scripts/verify-security.sh --skip-runtime build.noindex/UsageBar.app  # 起動していないアプリを検査（6 を省く）
scripts/verify-security.sh --binary /usr/bin/nc               # 実行ファイル 1 つに 3〜5 だけを行う（検査が NG を出せるかの確認用）
```

次を確かめます。

1. App Sandbox が有効で、通信の権限が無い
2. 読み取りを許可したパスが上の 4 か所だけで、ほかの entitlement が無い
3. 実行ファイルが、通信（`socket` / `connect` / `getaddrinfo` / `URLSession` / `Data(contentsOf:)` など）、別プログラムの起動（`posix_spawn` / `execve` / `Process` / `NSWorkspace.open` など）、動的な読み込み（`dlopen` / `NSClassFromString` など）、Keychain の読み出しに使う API を参照していない
4. 実行ファイルに URL の文字列が無い
5. システム以外のライブラリを読み込んでおらず、Network / CFNetwork / WebKit / Security のフレームワークも直接リンクしていない
6. 指定したアプリが起動していて、サンドボックスの中で動き、ネットワークのソケットを開いていない

検査に使う道具が失敗したときは、OK にせず NG にします。通信するプログラムに `--binary` で当てると NG になることを確かめてあります（`nc` は `connect` / `getaddrinfo` などで、URLSession を使うプログラムは `NSURLSession` と `dataTaskWithURL:` で、`curl` は埋め込まれた URL で NG）。中継コマンドはサンドボックスの外で動くので、3 と 4 が「通信しない」ことの主な根拠です。実行時に組み立てた URL までは見つけられないため、ソースの確認と合わせて使ってください。

## インストール

Xcode（Command Line Tools ではなく Xcode 本体）が必要です。

```bash
scripts/build-app.sh --install      # ~/Applications/UsageBar.app に配置
open ~/Applications/UsageBar.app
```

`~/Applications` に置くと、Raycast や Spotlight で「UsageBar」と打てば出てきます。組み立て途中のアプリは `build.noindex/` に作ります。`.noindex` の付いたフォルダは Spotlight が索引しないので、検索に出るのは配置したアプリだけです。

ad-hoc 署名でローカル用に署名します。Apple の公証には出していません（何も送信しません）。

### Claude の使用率を表示する

Claude の使用率は、Claude Code のステータスライン経由で受け取ります。一度だけ次を実行してください。

```bash
~/Applications/UsageBar.app/Contents/MacOS/usagebar-bridge install
```

`~/.claude/settings.json` の `statusLine` にこのコマンドを登録します。元のファイルは `settings.json.usagebar-backup-<日時>` として残します。ファイルを書き直すため、キーの並び順は変わります。すでに別の `statusLine` があるときは、上書きせずに止まります（`--force` で上書き）。

登録すると、Claude Code の画面下部にも `Opus 5.5 │ 5h 23% ↻2h10m │ 7d 41% │ ctx 12%` のような行が出ます。

```bash
usagebar-bridge status      # 受け取った最新の値を表示
usagebar-bridge uninstall   # 登録を外す
```

Claude Code の利用上限は、Claude.ai のサブスクリプション（Pro / Max / Team / Enterprise）でログインしているときだけ届きます。API キーで使っている場合は、トークン数だけを表示します。

## 制約

- Claude の使用率は、Claude Code を使っているあいだに更新されます。使っていないあいだは最後に受け取った値を表示し、リセット時刻を過ぎた枠は 0% として扱います。
- Claude Code を複数開いていると、しばらく応答を受けていないセッションが古い値を送ってくることがあります。同じ枠の使用率は減らないので、中継コマンドは枠ごとに「リセット時刻が後の方、同じなら使用率が大きい方」を残します。
- `~/.claude/usagebar/` が無い状態でアプリを起動した場合、初めて値が届いてから表示されるまでに最大 30 秒かかります（フォルダの監視を始めるのが次の見直しのときになるため）。2 回目からは 1 秒以内です。
- Codex の古いログは、Codex CLI が `.jsonl.zst` に圧縮します（手元では約 1 週間後）。zstd の展開は Apple のフレームワークにないため、圧縮済みのログはトークン数の集計に含めません。使用率は最新のログから読むので影響しません。
- `CLAUDE_CONFIG_DIR` や `CODEX_HOME` で場所を変えている場合は読めません。サンドボックスで読める場所を固定しているためです。

## 開発

```bash
swift test                                         # 単体テスト
swift build --product UsageBar && \
  "$(swift build --show-bin-path)/UsageBar" --render-preview /tmp/usagebar   # 画面を PNG に書き出す（サンドボックス外のデバッグビルドで）
build.noindex/UsageBar.app/Contents/MacOS/UsageBar --print-summary                   # サンドボックスの中で集計結果を表示
/usr/bin/log show --last 10m --predicate 'subsystem == "local.usagebar"'     # 使用率が更新された記録（数値だけ）
```

| ディレクトリ | 内容 |
|---|---|
| `Sources/UsageCore` | ログの解析と集計。UI に依存しない |
| `Sources/UsageBar` | メニューバーのアプリ（SwiftUI の `MenuBarExtra`） |
| `Sources/UsageBarBridge` | Claude Code のステータスライン用の中継コマンド |
| `Resources` | Info.plist と entitlements |
| `scripts` | 組み立て、セキュリティの検査、アイコンの生成（`swift scripts/make-icon.swift Resources/AppIcon.icns`） |
