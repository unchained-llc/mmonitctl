# mmonit-cli-ng

M/Monit の HTTP API を使って、ホスト監視の停止/再開を行う `sh + jq` ベースのCLIです。

## 機能

- `updownio` と揃えた CLI 体験（ロゴ表示・対話メニュー・進捗表示）
- 全ホストの監視停止: `stop-all`（`status=2: Ignored`）
- 全ホストの監視開始: `start-all`（`status=0: Active`）
- 指定グループの監視停止: `stop-group <group>`
- 指定グループの監視開始: `start-group <group>`
- エラーチェック: `check`（異常が1件でもあれば `exit 1`、なければ `exit 0`）
- 並列リクエスト実行（`MMONIT_CONCURRENCY`）

## 要件

- POSIX `sh`
- `curl`
- `jq`

## インストール

```sh
make install
```

デフォルトインストール先: `/usr/local/bin/mmonitctl`

## 初回設定

初回実行時に、次の情報を対話入力して `config.json` に保存します。

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
# 対話メニューを開く（updownio 互換の操作感）
# 3/4: グループ一覧を表示し、Spaceで選択、/でフィルタ、Enterで停止/開始
# 5/6: ホスト一覧を表示し、Spaceで選択、/でフィルタ、Enterで停止/開始
mmonitctl

# 全ホスト停止（Ignored）
mmonitctl stop-all

# 全ホスト開始（Active）
mmonitctl start-all

# 異常有無チェック（異常ありなら終了コード1）
mmonitctl check
mmonitctl check --invert-exit

# ホスト選択UI（一覧・選択・フィルタ）
mmonitctl stop
mmonitctl start

# グループ名で停止/開始
mmonitctl stop-group "web"
mmonitctl start-group "web"

# グループIDでも指定可能
mmonitctl stop-group 94
mmonitctl start-group 94
```

## 環境変数

- `MMONIT_BASE_URL`
- `MMONIT_USERNAME`
- `MMONIT_PASSWORD`
- `MMONIT_CONFIG_DIR`
- `MMONIT_CONCURRENCY`（デフォルト: `8`）
- `NO_COLOR=1`

`MMONIT_BASE_URL` / `MMONIT_USERNAME` / `MMONIT_PASSWORD` を指定すると、保存済み設定より優先されます。

## API利用方針

- 認証: Basic認証（`-u user:pass`）
- CSRFトークン取得: `GET /api/2/session/get`
- ホスト一覧: `GET /api/2/admin/hosts/list`
- ホスト詳細: `GET /api/2/admin/hosts/get?id=<id>`
- ホスト更新: `POST /api/2/admin/hosts/update`
- グループ一覧: `GET /api/2/admin/groups/list`

`hosts/update` では `status` だけでなく、`hosts/get` で取得した必要パラメータ（`hostname`, `monituser`, `monitpassword`, `ipaddrout`, `portout`, `keepname`, `skew`, `description`）を引き継いで更新しています。

## 開発

```sh
make lint
make test
```

## トラブルシュート

- `401` が出る場合
  - Base URL が正しいか（プロキシ配下のパス含む）
  - ユーザー権限で `/api/2/admin/*` が許可されているか
- 実行速度を上げたい場合
  - `MMONIT_CONCURRENCY` を増やす（例: `MMONIT_CONCURRENCY=16 mmonitctl stop-all`）
