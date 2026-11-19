# AGENTS.md

このファイルは、このリポジトリで作業するAIコーディングエージェント向けの実装・運用ガイドです。

## プロジェクト目的

`mmonit-cli-ng` は、M/Monit の API を利用してホスト監視状態を一括変更する CLI です。

対象機能:

- 全ホストの監視停止
- 全ホストの監視開始
- 指定グループの監視停止
- 指定グループの監視開始

## 技術制約

- 実装言語は `sh`（POSIX）
- JSON処理は `jq`
- Python / Go / Node.js は使わない
- 外部依存は最小限（`curl`, `jq`, `awk`, `mktemp`, `stty`）

## 重要な仕様

- 停止は `status=2`（Ignored）
- 再開は `status=0`（Active）
- `status=1` は Inactive であり、監視停止意図とは異なるため停止コマンドでは使わない
- `POST /api/2/admin/hosts/update` 時は、`hosts/get` の詳細値を引き継いで送る
- 全APIコマンドで最初に `GET /api/2/session/get` を呼び、取得したCookieを後続リクエストで共有する
- 終了時は `POST /api/2/session/invalidate` で自身のセッションを破棄する。エラー・シグナル終了でも、並列ワーカーの完了後に親プロセスが1回だけ破棄する
- 旧バージョンが返す `CSRFToken` は更新時ヘッダに付与する。4.4.0以降のトークンなし応答 `{}` も正常として扱う
- ホスト一覧のページ指定は `startindex` / `results` を使い、`totalRecords` がある場合は全件取得するまで継続する。不完全な一覧で一括更新しない
- 4.4.0の `monitpassword` の予約値 `........` は変更せず再送し、保存済みパスワードを保持する

## API利用

- `GET /api/2/session/get`
- `GET /api/2/admin/hosts/list`
- `GET /api/2/admin/hosts/get?id=<id>`
- `POST /api/2/admin/hosts/update`
- `GET /api/2/admin/groups/list`

認証は Basic認証（`-u user:pass`）を使用。

## パフォーマンス方針

- 一括更新は並列実行を維持する
- 並列数は `MMONIT_CONCURRENCY` で制御（デフォルト8）
- API呼び出しの直列化を増やす変更は避ける

## コーディング方針

- 既存の出力フォーマット（進捗表示、成功/失敗表示）を維持
- 既存のエラーハンドリングパターンに合わせる
- 不要な大規模リファクタをしない
- シークレット値（ユーザー名/パスワード）をログに出さない

## 変更時の確認

変更後は必ず以下を実行:

```sh
make lint
make test
```

追加で確認すること:

- `stop-all` が `status=2` を送ること
- `start-all` が `status=0` を送ること
- `stop-group` / `start-group` が group 名と ID の両方で動くこと
