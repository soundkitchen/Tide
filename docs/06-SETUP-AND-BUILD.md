# 開発環境セットアップとビルド

## 必要なもの

- macOS 26.0 (Tahoe) 以降
- Xcode 17 以降
- AWS アカウント
- テスト用 S3 バケット
- AWS IAM ユーザー（テスト用、最小権限）

## AWS 側の準備

### テスト用 S3 バケット作成

```bash
# AWS CLI で作成（東京リージョンの例）
aws s3 mb s3://your-tide-test-bucket --region ap-northeast-1
```

### IAM ユーザー作成と権限付与

> ⚠️ **静的アクセスキーは強い権限**で、流出時には**バケット内ファイルの全消去まで可能**になります。
> このキーは Tide のローカル Keychain に長期保持されるため、流出時の被害を最小化するために、
> このバケットのみへ限定する **以下の最小権限ポリシー** を必ずアタッチしてください。
> 将来的には IAM Identity Center / STS AssumeRole / 一時クレデンシャルへの置き換えを推奨します。

最小権限ポリシー（テスト用バケットだけにアクセス可能）:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketVersioning",
                "s3:PutBucketVersioning",
                "s3:GetLifecycleConfiguration",
                "s3:PutLifecycleConfiguration",
                "s3:PutBucketPublicAccessBlock",
                "s3:ListBucketVersions"
            ],
            "Resource": "arn:aws:s3:::your-tide-test-bucket"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:GetObjectVersion",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:DeleteObjectVersion",
                "s3:GetObjectAcl",
                "s3:PutObjectAcl"
            ],
            "Resource": "arn:aws:s3:::your-tide-test-bucket/*"
        }
    ]
}
```

このユーザーのアクセスキー ID とシークレットアクセスキーを発行し、アプリのセットアップウィザードで使用する。

#### バケットも Tide から作成したい場合（オプション）

M1 のセットアップウィザードは「バケットが存在しなければ作成しますか？」と尋ねる。アプリ内からバケットを作成するなら、上記とは別途、以下のステートメントを **アタッチして、初回作成後に剥がす** のが推奨運用:

```json
{
    "Effect": "Allow",
    "Action": [
        "s3:CreateBucket"
    ],
    "Resource": "arn:aws:s3:::your-tide-test-bucket"
}
```

事前に AWS CLI でバケットを作っておけば（このページ冒頭の `aws s3 mb` のとおり）、上の追加権限は不要。

## プロジェクトのビルド

### コマンドラインから

```bash
cd /path/to/Tide

# デバッグビルド
xcodebuild -project Tide.xcodeproj \
           -scheme Tide \
           -configuration Debug \
           -derivedDataPath ./build

# 生成物
ls ./build/Build/Products/Debug/Tide.app
```

### Xcode から

通常通り `cmd+R` で実行。

### リリースビルド & インストール

自分専用なので簡単に `~/Applications/` に置く:

```bash
xcodebuild -project Tide.xcodeproj \
           -scheme Tide \
           -configuration Release \
           -derivedDataPath ./build

# ~/Applications に配置
rm -rf ~/Applications/Tide.app
cp -R ./build/Build/Products/Release/Tide.app ~/Applications/

# 起動
open ~/Applications/Tide.app
```

コード署名なしで起動時に Gatekeeper に止められる場合:
```bash
xattr -d com.apple.quarantine ~/Applications/Tide.app
```

## 自動起動の設定

macOS のログイン項目に登録するには:

1. アプリ起動状態で `System Settings` > `General` > `Login Items`
2. `+` ボタンで `Tide.app` を追加

または、`SMAppService` API を使ってアプリ内から設定する機能を追加（M4 で検討）。

## デバッグ Tips

### ログの確認

Console.app で以下のフィルタ:
- Subsystem: `com.example.tide`
- Process: `Tide`

コマンドラインなら:
```bash
log stream --predicate 'subsystem == "com.example.tide"' --level debug
```

### ローカル DB の確認

```bash
sqlite3 ~/Library/Application\ Support/Tide/db.sqlite

sqlite> .tables
sqlite> .schema files
sqlite> SELECT * FROM files LIMIT 5;
sqlite> SELECT * FROM upload_queue WHERE next_retry_at IS NOT NULL;
sqlite> SELECT * FROM sync_log ORDER BY timestamp DESC LIMIT 20;
```

### マニフェストの確認

```bash
aws s3 cp s3://your-bucket/.tide/index.json - | jq
aws s3 cp s3://your-bucket/.tide/shards/a3.json - | jq
```

### S3 オブジェクトのバージョン一覧

```bash
aws s3api list-object-versions \
    --bucket your-bucket \
    --prefix files/Documents/report.pdf
```

### バケット初期化（テスト時）

```bash
# 全バージョン削除（テスト環境のみ）
aws s3api list-object-versions --bucket your-bucket \
    --query 'Versions[].{Key:Key,VersionId:VersionId}' \
    --output json | \
    jq -c '.[]' | \
    while read obj; do
        key=$(echo $obj | jq -r .Key)
        version=$(echo $obj | jq -r .VersionId)
        aws s3api delete-object --bucket your-bucket --key "$key" --version-id "$version"
    done

# delete marker も削除
aws s3api list-object-versions --bucket your-bucket \
    --query 'DeleteMarkers[].{Key:Key,VersionId:VersionId}' \
    --output json | \
    jq -c '.[]' | \
    while read obj; do
        key=$(echo $obj | jq -r .Key)
        version=$(echo $obj | jq -r .VersionId)
        aws s3api delete-object --bucket your-bucket --key "$key" --version-id "$version"
    done
```

### ローカルアプリのリセット

```bash
# ローカル DB を削除
rm -rf ~/Library/Application\ Support/Tide

# 設定削除
defaults delete com.example.tide

# Keychain からも削除（手動で Keychain Access から、または）
security delete-generic-password -s com.example.tide
```

## 既知の落とし穴

### 1. App Sandbox を有効にすると同期フォルダにアクセスできない

M1 では Sandbox オフで開発。本格配布する場合は:
- `com.apple.security.files.user-selected.read-write` 権限を追加
- ブックマークデータでフォルダアクセスを永続化

### 2. FSEvents が外付けディスクで動かない

外付け SSD やネットワーク共有上の同期フォルダでは FSEvents が動かない、または挙動が異なる場合がある。M1 では内蔵ディスクのみサポート。

### 3. iCloud Drive 内のフォルダを同期対象にしない

`~/Library/Mobile Documents/` 配下や iCloud Drive のフォルダを指定すると、iCloud と Tide が互いに変更を打ち消し合う無限ループになる可能性がある。セットアップウィザードでバリデーションを入れる。

### 4. Time Machine のスナップショットフォルダ

`.Spotlight-V100`、`.fseventsd`、`.Trashes` など、システムが管理する隠しフォルダは除外必須。

## パッケージ更新

```bash
# Swift Package Manager の依存を最新化
xcodebuild -resolvePackageDependencies -project Tide.xcodeproj
```

Xcode 上では File > Packages > Update to Latest Package Versions。
