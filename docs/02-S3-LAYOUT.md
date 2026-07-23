# S3 バケットレイアウトとマニフェスト仕様

## バケット構造

```
s3://<user-bucket>/
├── files/                          ← 実ファイル本体（同期フォルダのミラー）
│   ├── Documents/report.pdf
│   ├── Photos/2024/IMG_0001.jpg
│   ├── .git/objects/ab/cd...        ← .git も含める
│   └── ...
└── .tide/                         ← メタデータ（プレフィックスにドットを付けて目立たせる）
    ├── index.json                  ← 軽量インデックス（常にこれだけポーリング）
    └── shards/
        ├── 00.json
        ├── 01.json
        ├── ...
        └── ff.json                 ← 最大256シャード（先頭2hex）
```

## キー命名規約

- ファイル本体: `files/<相対パス>`
  - 同期フォルダ内の `Documents/foo.txt` → `files/Documents/foo.txt`
  - パスの区切りは常に `/`（POSIX 形式）
  - 大文字小文字は保持（S3 はケースセンシティブ）
  - スペース・日本語・絵文字: そのまま使用（URL エンコードは AWS SDK 任せ）
- マニフェスト: `.tide/index.json`, `.tide/shards/XX.json`

## index.json 仕様

**目的**: 各シャードの ETag だけ持つ軽量インデックス。ポーリング時はこれだけ取得する。

**サイズ目安**: シャード256個 × 80byte = 約 20KB（最大）

```json
{
  "version": 1,
  "updated_at": "2026-05-23T10:30:00Z",
  "updated_by": "MacBookPro-Yuta-A1B2C3",
  "shards": {
    "00": { "etag": "abc123...", "count": 412 },
    "01": { "etag": "def456...", "count": 389 },
    "...": "...",
    "ff": { "etag": "xyz789...", "count": 401 }
  }
}
```

### フィールド説明

- `version`: スキーマバージョン。互換性のない変更時にインクリメント。
- `updated_at`: 最終更新日時（ISO8601 UTC）。
- `updated_by`: 最後に更新したデバイスの ID。デバッグ・トラブルシューティング用。
- `shards`: シャードのマップ。キーは2桁の hex 文字列。
  - `etag`: そのシャード JSON の S3 ETag。シャード内容が変わると変わる。
  - `count`: シャードに含まれるファイル数。シャードバランス確認用。

### 空シャードの扱い

そのシャードに該当するファイルが1つもない場合、`shards` マップにキー自体を含めない。シャード JSON も S3 に作らない。

## shards/XX.json 仕様

**目的**: ファイルメタデータの本体。シャードごとに独立して読み書きする。

**サイズ目安**: シャードあたり数百〜数千ファイル、数十KB〜数百KB。

```json
{
  "version": 1,
  "shard_id": "a3",
  "updated_at": "2026-05-23T10:29:55Z",
  "files": {
    "Documents/report.pdf": {
      "size": 1048576,
      "mtime": "2026-05-22T14:00:00Z",
      "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "s3_version_id": "abcXYZ123",
      "etag": "9bb58f26192e4ba00f01e2e7b136bbd8",
      "device_id": "MacBookPro-Yuta-A1B2C3",
      "uploaded_at": "2026-05-22T14:00:15Z"
    },
    "Photos/2024/IMG_0001.jpg": {
      "size": 5242880,
      "mtime": "2024-12-30T18:42:11Z",
      "sha256": "...",
      "s3_version_id": "...",
      "etag": "...",
      "device_id": "...",
      "uploaded_at": "..."
    }
  }
}
```

### フィールド説明

- `version`: スキーマバージョン。
- `shard_id`: 自分のシャード ID（2桁 hex）。冗長だが整合性チェック用。
- `updated_at`: このシャードの最終更新日時。
- `files`: ファイルパス → メタデータのマップ。
  - キー: 同期ルートからの相対パス（POSIX 区切り）。
  - `size`: バイト数。
  - `mtime`: ファイルの修正時刻（ローカルファイルシステムから取得）。ISO8601 UTC。
  - `sha256`: ファイル内容の SHA-256。hex 小文字。
  - `s3_version_id`: アップロード時に S3 が返した version ID。省略可（バージョニング無効バケット等では無し。`ManifestFileEntry.s3VersionId` は `String?`）。
  - `etag`: S3 が返した ETag。シングルパートアップロードなら MD5 と一致。**マルチパート（M3、16MiB 超）では `<md5>-<partcount>` 形式**。整合性検証は `sha256` ベースなので etag は情報用途（パース不要）。
  - `device_id`: アップロードしたデバイスの ID。
  - `uploaded_at`: アップロード完了時刻。

## シャーディングアルゴリズム

ファイルパスから所属シャードを決定する関数:

```swift
func shardId(for path: String) -> String {
    // SHA-1 を使う（速いから、暗号強度は不要）
    let hash = Array(Insecure.SHA1.hash(data: Data(path.utf8)))
    let firstByte = hash[0]
    return String(format: "%02x", firstByte)
}
```

**重要**: SHA-256 ではなく SHA-1 を使う。理由はパスのハッシュ値の先頭バイトだけ欲しいので、速さ優先。`CryptoKit.Insecure.SHA1` で取れる。

**なぜハッシュ振り分けか**: ファイル名の頭文字（例: A-Z）で振り分けると、`Documents/` や `Photos/` に偏って分布が不均等になる。ハッシュなら均等に分布する。

## マニフェスト更新の楽観的ロック

複数の Mac が同時に同じシャードを更新する競合を防ぐため、`If-Match` ヘッダで現在の ETag を指定して PUT する。

### 更新手順（あるファイルをアップロードした後）

```
1. files/<path> を PUT して PutObjectResult を得る
   ├─ version_id, etag を取得
   
2. shard_id = shardId(for: path)

3. ループ開始（最大5回）:
   a. S3 から shards/<shard_id>.json を GET
      ├─ 現在の ETag を保存
      ├─ JSON をパース
      └─ もし 404 なら空のシャードを作る
   b. files マップに新しいエントリを追加・更新
   c. updated_at を更新
   d. PUT で書き戻す
      ├─ If-Match: <現在の ETag> を指定
      ├─ 成功 → ステップ 4 へ
      └─ 412 Precondition Failed / 409 ConditionalRequestConflict → ループ先頭に戻る
         （409 は同一キーへの並行条件付き PUT が同時実行された時の一時的衝突。再取得で解消する）
   
4. index.json を更新（同じく楽観的ロック）:
   a. GET で現在の index.json を取得
   b. shards[<shard_id>].etag を新しい値に更新
   c. PUT で書き戻す（If-Match）
   d. 失敗したらリトライ
```

### S3 の制約に注意

S3 は `If-Match` を `PutObject` でサポートする。条件付き書き込み機能（2024年以降）を使う。

```swift
// AWS SDK for Swift での指定例
let input = PutObjectInput(
    body: .data(jsonData),
    bucket: bucket,
    contentType: "application/json",
    ifMatch: expectedETag,  // ← これ
    key: ".tide/shards/a3.json"
)
```

新規作成の場合は `ifNoneMatch: "*"` を指定すると、既存ファイルがあれば失敗する（race condition 対策）。

## バージョニング設定

初回セットアップ時にアプリが自動的に有効化する。

```swift
let request = PutBucketVersioningInput(
    bucket: bucket,
    versioningConfiguration: VersioningConfiguration(status: .enabled)
)
```

### バージョン復元 / 削除済み復元 (M4)

バージョニングと delete marker を使って「過去バージョン参照」「削除済みファイルの復元」を行う。

- **列挙**: `TideS3Client.listObjectVersions(prefix:keyMarker:versionIdMarker:maxKeys:)`（`ListObjectVersions`）で `files/` 配下の版・delete marker をページング取得する。生 SDK 型は Tide 独自の Sendable 値（`ObjectVersionPage` / `S3ObjectVersionRaw` / `S3DeleteMarkerRaw`）に詰め替える。整形（相対パスごとのグルーピング・時系列降順・削除済み集合）は純粋関数 `ObjectVersionHistory` に集約（`files/` を剥がし `PathValidator.validateRelativePath` に通らない不正キーは除外）。
  - **特定ファイルの履歴**は `prefix = files/<相対パス>` で 1 key に絞れる＝安価。
  - **全削除済み一覧**は `prefix = files/` 全体を舐めるため高コスト。よって**明示ボタンでのみ**フル列挙し、ページングしながら逐次表示・キャンセル可とする（ポーリングには乗せない）。
- **遡及窓**: ライフサイクル `tide-expire-old-versions`（NoncurrentDays=90）/ `tide-expire-delete-markers` により、復元できるのは概ね**直近 90 日**ぶん。
- **取得**: `getObject` / `headObject` / `streamObject` は `versionId` を受けられる。復元は特定 `versionId` を `streamObject(versionId:)` でストリーミング DL する。
- **整合性**: マニフェスト（`index.json` / shards）は**現行状態のみ**を表し、過去版・削除済みは含まない。よって**過去版には sha256 が無い**。履歴 DL では SHA 突合せず、`headObject(versionId:)` の真実サイズ（`Content-Length`）を上限ガード（ローカルディスク枯渇 DoS = M7 を復元でも維持）＆実サイズ突合に使う。復元後は通常 upload 経路で新マニフェストに sha256 が載り、以後の整合性は既存保証へ合流する。
- **方式**: 「ローカルへ書き戻し → 再アップロード」（`RestoreService`・folderSync モード）。選んだ版を一時ファイルへ DL → `PathValidator.resolveForWrite` + symlink 非追従で原パス（または別名退避）へ atomic move → FileWatcher が拾って新しい**現行版**として上げ直す（DB は触らない）。S3 内 CopyObject 方式は採らない（マニフェスト整合の設計コストが高い・据え置き。過去版に sha256 が無いため CopyObject では新マニフェスト entry を作れない）。
- **fpOnly モードの復元（M5 Track B-2）**: ローカル面（syncRoot / DB）が無いため「**S3 内復元**」= `S3RestoreService`（tmp DL → sha256 計算 → 新しい現行版として PUT → `ManifestUpdater` 合流）。DL→PUT なので「過去版に sha が無い」制約と整合（sha は復元時に計算してマニフェストへ載る）。整合性モデル・遡及窓は上記と同一。バージョン履歴上は「復元 = 新しい現行版が 1 つ積まれる」で folderSync と同じ見え方。詳細は `docs/08`「FP-only 稼働モード B-2」節。
- **復元先（ハイブリッド）**: 原パスへ書き戻す。ただしローカルに既存ファイルがあり現在 SHA が DB 記録（最後に同期した SHA）と食い違う＝未同期編集なら、`(restored YYYY-MM-DD HH-MM-SS)` の別名へ退避して上書きを避ける（純粋関数 `RestoreTarget.decide`）。
- **rename / reparent（M5 Phase 5-4・FP 拡張の move）の版履歴上の見え方**: move は `CopyObject`（versionId 固定・サーバサイド）+ 旧キーへの delete marker で実現するため、**旧 path** には「それまでの版履歴 + delete marker」が残り（= 削除済み一覧に出る・90 日窓で回復可）、**新 path** はコピー結果を初版とする新しい履歴が始まる。**版履歴は path を跨いで繋がらない**（改名前の版を見るには旧 path 側を辿る）。move を繰り返すたびに旧 path 側へ孤児版が積まれるが、ライフサイクル失効（NoncurrentDays=90）で回収される — アップロード競合の orphan version と同じ扱い。

## Public Access Block (M2 で追加)

初回セットアップ時に `TideS3Client.enforcePublicAccessBlock` で **4 設定すべて true** を投入する:

```swift
PutPublicAccessBlockInput(
    bucket: bucket,
    publicAccessBlockConfiguration: PublicAccessBlockConfiguration(
        blockPublicAcls: true,
        blockPublicPolicy: true,
        ignorePublicAcls: true,
        restrictPublicBuckets: true
    )
)
```

ユーザがコンソール等で将来うっかりバケットを公開設定にする事故をアプリ側で塞ぐ。
IAM ポリシーに `s3:PutBucketPublicAccessBlock` が必要 (`docs/06-SETUP-AND-BUILD.md` 参照)。

## サーバサイド暗号化 (M2 で追加)

`PutObject` には常に `serverSideEncryption: .aes256` を明示する（バケット側のデフォルト暗号化に依らない）:

```swift
let input = PutObjectInput(
    body: .data(data),
    bucket: bucket,
    contentType: contentType,
    key: key,
    metadata: metadata,
    serverSideEncryption: .aes256
)
```

## ライフサイクルルール

初回セットアップ時に自動投入。3つのルール:

> **適用方針（M2 で確定）**: `TideS3Client.ensureLifecycleRules` は **マージ方式** で動く。
> 既存ルールを `GetBucketLifecycleConfiguration` で取得して、`tide-` プレフィックスを持つ ID は Tide 製とみなして
> 内容を最新の定義に差し替え、それ以外のユーザ独自ルールは **温存** する。3 ID すべて揃っていれば PUT もスキップ。
> 結果として、ユーザがコンソールで手動投入したカスタムルールを破壊しない。

### ルール1: マルチパートアップロードの掃除（必須）

未完了のマルチパートアップロードを7日後に自動削除。コスト事故防止。

```json
{
  "ID": "tide-abort-incomplete-multipart",
  "Status": "Enabled",
  "Filter": { "Prefix": "" },
  "AbortIncompleteMultipartUpload": {
    "DaysAfterInitiation": 7
  }
}
```

### ルール2: 古い旧バージョンの削除

90日以上経過した非カレントバージョンを削除。

```json
{
  "ID": "tide-expire-old-versions",
  "Status": "Enabled",
  "Filter": { "Prefix": "" },
  "NoncurrentVersionExpiration": {
    "NoncurrentDays": 90
  }
}
```

### ルール3: 古い delete marker の掃除

1年以上経過し、配下のバージョンが全て期限切れになった delete marker を削除。

```json
{
  "ID": "tide-expire-delete-markers",
  "Status": "Enabled",
  "Filter": { "Prefix": "" },
  "Expiration": {
    "ExpiredObjectDeleteMarker": true
  }
}
```

## S3 オブジェクトメタデータ

各ファイル本体には以下のユーザーメタデータを付ける（`x-amz-meta-*`）。

```
x-amz-meta-mtime: <iso8601-utc>
x-amz-meta-device: <device-id>
x-amz-meta-size: <bytes>
```

注意: メタデータは ASCII 推奨。日本語ファイル名は値ではなくキー（オブジェクトキー）に含まれるので問題ない。

**M3 で `x-amz-meta-sha256` は付けない**。マルチパートでは `CreateMultipartUpload` 時点で sha256 が未確定（全パートを読むまで分からない）であり、シングルパート経路も両者の挙動を揃えるため外した。**ファイル内容の整合性の真実は `ManifestFileEntry.sha256`**（ダウンロード時の検証もこれを使う）であり、object metadata の sha256 を参照する経路は無い。

## クリーンインストール復旧シナリオ（M2 で実装）

新しい Mac で:
1. アプリ起動 → 認証情報入力 → バケット選択
2. `index.json` を GET
3. 全シャードを並列で GET
4. シャードの内容に従って `files/*` から全ファイルを並列ダウンロード
5. ローカル DB を構築

`index.json` が存在しなければ、`ListObjectsV2` で `.tide/shards/` を一覧して、そこから index を再構築できる。さらに最悪 `files/*` も `ListObjectsV2` で全列挙すれば、メタデータ（オブジェクトの `x-amz-meta-*`）から完全復旧可能。
