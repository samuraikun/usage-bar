# Security Policy

[日本語は下にあります](#日本語)

## Reporting a vulnerability

Please do not open a public issue for security problems. Report them privately through GitHub instead: open the **Security** tab of this repository and choose **Report a vulnerability**.

Please include:

- what an attacker could do,
- the steps to reproduce,
- the macOS version, and the Claude Code or Codex CLI version if relevant.

This is a personal project, so there is no guaranteed response time. Reports are read and answered as soon as possible.

## What UsageBar protects, and what it does not

UsageBar is designed so that it cannot send anything off your Mac and cannot read your credentials. These properties count as security issues:

| Property | How it is enforced | How to check |
|---|---|---|
| The app makes no network connections | App Sandbox without `com.apple.security.network.client` or `network.server` | `scripts/verify-security.sh`, steps 1 and 6 |
| The app reads only four directories, read-only | Sandbox file exceptions in `Resources/UsageBar.entitlements` | `scripts/verify-security.sh`, step 2 |
| Credentials (`~/.codex/auth.json`, `~/.claude/.credentials.json`, the Keychain) are never read | Outside the sandbox exceptions; no Keychain APIs | `scripts/verify-security.sh`, steps 2 and 3 |
| `usagebar-bridge` writes only numbers (percentages and times) and, for per-model windows, the model label reduced to letters, digits and a few symbols | Code review and unit tests | `Tests/UsageCoreTests` |
| Malformed or hostile log files cannot crash the app or make it read outside those directories | Size limits, no symlink following, clamped values | `Tests/UsageCoreTests/HardeningTests.swift` |

Known limits that are **not** treated as vulnerabilities:

- **`usagebar-bridge` runs outside the sandbox.** Claude Code starts it as the status line command, and it must write `~/.claude/usagebar/` and, when you run `install`, `~/.claude/settings.json`. To get per-model windows (such as Fable) it also reads `~/.claude.json`, Claude Code's own state file, which holds account and project details and can hold MCP server settings (the Claude login token is in the Keychain, not in this file). Only the cached usage numbers and model labels are kept; everything else is discarded and never written anywhere. It is kept small and checked for network APIs, but macOS does not stop it from connecting. A change that adds network access to it *is* a vulnerability.
- **Anyone who can already write to `~/.claude/` or `~/.codex/` as your user** can make UsageBar show wrong numbers. That is outside the threat model, because such an attacker already controls those CLIs.
- **Builds are signed ad hoc on your own Mac.** No signed binaries are published. Only build from source that you have read.

---

## 日本語

### 脆弱性の報告

セキュリティの問題は、公開の Issue に書かないでください。GitHub の非公開の窓口から知らせてください。このリポジトリの **Security** タブを開き、**Report a vulnerability** を選びます。

次の内容を書いてください。

- 攻撃者に何ができるか
- 再現の手順
- macOS のバージョン（関係するなら Claude Code や Codex CLI のバージョンも）

個人で作っているものなので、返事までの期間は約束できません。届いた報告はできるだけ早く読んで返事をします。

### 守っていること・守っていないこと

UsageBar は、手元から外に何も送れず、認証情報も読めないように作っています。次の性質が崩れるものは、セキュリティの問題として扱います。

| 性質 | 守り方 | 確かめ方 |
|---|---|---|
| アプリは外部と通信しない | App Sandbox に入れ、`com.apple.security.network.client` と `network.server` を付けない | `scripts/verify-security.sh` の 1 と 6 |
| アプリが読むのは 4 か所だけで、読み取り専用 | `Resources/UsageBar.entitlements` のサンドボックスの例外 | `scripts/verify-security.sh` の 2 |
| 認証情報（`~/.codex/auth.json`、`~/.claude/.credentials.json`、Keychain）を読まない | サンドボックスの例外に含めない。Keychain の API を使わない | `scripts/verify-security.sh` の 2 と 3 |
| `usagebar-bridge` が書くのは数値（使用率と時刻）と、モデルごとの枠のモデル名（英数字と一部の記号だけに絞ったもの）だけ | コードの確認と単体テスト | `Tests/UsageCoreTests` |
| 壊れたログや細工されたログで、アプリが止まったり、4 か所の外を読んだりしない | 大きさの上限、シンボリックリンクをたどらない、値の範囲を抑える | `Tests/UsageCoreTests/HardeningTests.swift` |

次は既知の制約で、脆弱性としては扱いません。

- **`usagebar-bridge` はサンドボックスの外で動く。** Claude Code がステータスライン用のコマンドとして起動し、`~/.claude/usagebar/` に書きます。`install` を実行したときは `~/.claude/settings.json` も書きます。Fable などモデルごとの枠を得るために、Claude Code 自身の状態ファイル `~/.claude.json` も読みます。このファイルにはアカウントやプロジェクトの情報があり、MCP サーバーの設定が入っていることもあります（Claude のログイン用のトークンは Keychain にあり、このファイルにはありません）。残すのは使用率の数値とモデル名だけで、ほかは読み捨て、どこにも書きません。そのため小さく保ち、通信用の API を含まないことを検査していますが、macOS が通信を止めるわけではありません。中継コマンドに通信を持ち込む変更は、脆弱性として扱います。
- **あなたの権限で `~/.claude/` や `~/.codex/` に書ける人がいる場合。** その人は UsageBar に誤った数値を出させることができます。ただ、その人は CLI 自体をすでに操れるので、想定する脅威の範囲外とします。
- **署名は、あなたの Mac の上で、あなた自身が行う（ad-hoc 署名）。** 署名済みのアプリは配布していません。中身を確かめたソースから組み立ててください。
