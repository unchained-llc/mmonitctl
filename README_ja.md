[English](README.md) | [日本語](README_ja.md)

# mmonit-cli-ng

M/Monit のホスト監視状態を操作する、POSIX `sh` + `jq` 製 CLI です。

実行コマンド: `mmonitctl`

## 機能

- 全ホスト停止: `stop-all`（`status=2` = Ignored）
- 全ホスト開始: `start-all`（`status=0` = Active）
- ホスト選択停止/開始: `stop` / `start`
- グループ指定停止/開始: `stop-group <group>` / `start-group <group>`（名前/ID対応）
- グループ選択停止/開始（メニュー経由）
- Homebridge 用の監視状態取得: `status`
  - 全ホストが `Active` なら成功（終了コード `0`）、1台でもそれ以外なら失敗（終了コード `1`）し、状態メッセージを表示
- アラートチェック: `health`
  - `GET /api/2/reports/events/list?active=1&state=1` を使用
  - アクティブなアラートイベントが1件以上なら `exit 1`
- 並列更新（`MMONIT_CONCURRENCY`、デフォルト `8`）
- アラートルールのOn/Off（全て、または検索して対話選択）

## 要件

- POSIX 互換 `sh`
- `curl`
- `jq`
- `awk`, `mktemp`, `stty`

## インストール

```sh
make install
```

デフォルトインストール先: `/usr/local/bin/mmonitctl`

## 初回設定

初回実行時に以下を入力します。

- M/Monit Base URL
- Username
- Password

保存先:

- macOS: `~/Library/Application Support/mmonitctl/config.json`
- Linux: `~/.config/mmonitctl/config.json`

再設定:

```sh
mmonitctl config
```

## 使い方

```sh
# メニューを開く
mmonitctl

# 全ホスト停止 / 開始
mmonitctl stop-all
mmonitctl start-all

# ホストを選択して停止 / 開始
mmonitctl stop
mmonitctl start

# グループ指定で停止 / 開始（名前・IDどちらも可）
mmonitctl stop-group web
mmonitctl start-group web
mmonitctl stop-group 94
mmonitctl start-group 94

# 全アラートルールをOff / On
mmonitctl alerts-off-all
mmonitctl alerts-on-all

# アラートルールを検索・選択してOff / On
mmonitctl alerts-off
mmonitctl alerts-on

# Homebridge の state_cmd 用（true / false を出力）
mmonitctl status

# アクティブアラートイベントの有無をチェック
mmonitctl health

# 終了コードを反転（alert=0, no-alert=1）
mmonitctl health --invert-exit
```

互換オプション（受け付けのみ）:

```sh
mmonitctl stop-all --yes
mmonitctl start-all --non-interactive
```

## メニュー

1. Stop all hosts
2. Start all hosts
3. Select hosts to stop
4. Select hosts to start
5. Select groups to stop
6. Select groups to start
7. Check host errors (exit status)
0. Cancel

追加メニューキー: `a` は全アラートOn、`s` は全アラートOff、
`d` は検索・選択してOff、`f` は検索・選択してOnです。

アラート選択画面では `/` でルール名・ID・On/Off状態を検索し、Enterで検索入力を終了、
Spaceで対象を選択、Enterで実行します。変更が必要なルールだけを表示します。
更新は並列で実行し、既に同じ状態のルールはスキップします。更新後は一覧を再取得して結果を確認します。
変更するのは通知ルールの有効状態だけで、ホストの監視状態やルール条件は維持します。

## 選択UIキー

| キー | 動作 |
|---|---|
| `k` / `↑` / `Ctrl-P` | 上へ移動 |
| `j` / `↓` / `Ctrl-N` | 下へ移動 |
| `Space` | 選択トグルして次の項目へ移動 |
| `A` | 現在表示中の項目を全選択 |
| `/` | フィルタ入力モード |
| `Enter` | 選択実行（またはフィルタ入力モード終了） |
| `Backspace` | フィルタ入力中に1文字削除 |
| `Esc` | フィルタ解除（選択UIは終了しない） |
| `q` | キャンセル |

## 環境変数

- `MMONIT_BASE_URL`
- `MMONIT_USERNAME`
- `MMONIT_PASSWORD`
- `MMONIT_CONFIG_DIR`
- `MMONIT_CONCURRENCY`（デフォルト `8`）
- `NO_COLOR=1`

`MMONIT_BASE_URL` / `MMONIT_USERNAME` / `MMONIT_PASSWORD` は保存済み設定より優先されます。

## API利用

- `GET /api/2/session/get`（CSRFトークン）
- `GET /api/2/admin/hosts/list`
- `GET /api/2/admin/hosts/get?id=<id>`
- `POST /api/2/admin/hosts/update`
- `GET /api/2/admin/groups/list`
- `GET /api/2/reports/events/list?active=1&state=1`（`health`）
- `GET /api/2/admin/hosts/list`（`status`）
- `GET /admin/alerts/list`（アラートルール一覧）
- `POST /admin/alerts/updateactive`（`id`、Onは`active=1`、Offは`active=0`）

アラート用の経路はM/Monit管理画面が使用しているもので、公開HTTP API資料には記載されていません。
M/Monitの更新時には互換性を確認してください。更新にはセッションのCSRFトークン・Cookieと既存のBasic認証設定を使用します。

`hosts/update` では、`hosts/get` で取得した値を `status` と一緒に引き継いで送信します。

## 開発

```sh
make lint
make test
```
