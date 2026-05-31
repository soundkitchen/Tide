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
  - `s3_version_id`: アップロード時に S3 が返した version ID。
  - `etag`: S3 が返した ETag。シングルパートアップロードなら MD5 と一致。
  - `device_id`: アップロードしたデバイスの ID。
  - `uploaded_at`: アップロード完了時刻。

## シャーディングアルゴリズム

ファイルパスから所属シャードを決定する関数:

```swift
func shardId(for path: String) -> String {
    // SHA-1 を使う（速いから、暗号強度は不要）
    let hash = SHA1.hash(data: Data(path.utf8))
    let firstByte = hash.first!
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
  "Filter": {},
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
  "Filter": {},
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
  "Filter": {},
  "Expiration": {
    "ExpiredObjectDeleteMarker": true
  }
}
```

## S3 オブジェクトメタデータ

各ファイル本体には以下のユーザーメタデータを付ける（`x-amz-meta-*`）。マニフェストが壊れた時の復旧用。

```
x-amz-meta-sha256: <sha256-hex>
x-amz-meta-mtime: <iso8601-utc>
x-amz-meta-device: <device-id>
x-amz-meta-size: <bytes>
```

注意: メタデータは ASCII 推奨。日本語ファイル名は値ではなくキー（オブジェクトキー）に含まれるので問題ない。

## クリーンインストール復旧シナリオ（M2 で実装）

新しい Mac で:
1. アプリ起動 → 認証情報入力 → バケット選択
2. `index.json` を GET
3. 全シャードを並列で GET
4. シャードの内容に従って `files/*` から全ファイルを並列ダウンロード
5. ローカル DB を構築

`index.json` が存在しなければ、`ListObjectsV2` で `.tide/shards/` を一覧して、そこから index を再構築できる。さらに最悪 `files/*` も `ListObjectsV2` で全列挙すれば、メタデータ（オブジェクトの `x-amz-meta-*`）から完全復旧可能。
