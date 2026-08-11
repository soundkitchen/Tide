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
                "s3:GetBucketPolicy",
                "s3:PutBucketPolicy",
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

> `s3:GetBucketPolicy` / `s3:PutBucketPolicy` は **HTTPS 強制バケットポリシー**（`aws:SecureTransport=false` を Deny・C3 後半）を適用するためのもの。これは**多層防御**（Tide 自身の通信は SDK が常に HTTPS）で、適用は**非致命**＝この 2 権限を外しても同期は動く（ポリシーが設定されないだけ）。最小化したい場合は外してよいが、外部ツールの HTTP アクセスを防ぐハードニングは無効になる。

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

#### バケット存在判定の挙動（HeadBucket と空ボディ応答）

セットアップウィザードは `Test & Provision` で `HeadBucket` を実行して存在を確認する。`HeadBucket` は HEAD なので応答ボディが空で、S3/AWS SDK の挙動には次の癖がある:

- **200** → バケットが存在しアクセス可能 → そのまま使用。
- **空ボディ 404** → SDK のカスタマイズで `NotFound` に変換 → 「作成または使用」フローへ。
- **空ボディ 403 / 301**（名前が他アカウントで使用中 / IAM に `s3:ListBucket` 権限が無い / リージョン不一致）→ smithy-swift が `<Code>` を読めず `missingRequiredData` を投げる。**この decode エラーには HTTP ステータスが乗らない**ため、Tide は存在を確定できない。

このため Tide は「`missingRequiredData` を含む HeadBucket 失敗」も **「バケットがありません。作成しますか？」の confirm を出してから `CreateBucket` を実行し、その結果で確定**させる:

- `CreateBucket` 成功 → 新規作成して使用。
- `BucketAlreadyOwnedByYou`（既存・自分の所有）→ **エラーにせずそのまま使用**（複数マシンで同じバケットに合流するための既存利用パス）。
- `BucketAlreadyExists`（他アカウントが使用中）→ 同期に使えないので「別の名前を」とエラー表示。
- `AccessDenied`（`s3:CreateBucket` 権限が無い）→ 「権限が不足しています。IAM ポリシーに s3:CreateBucket が必要です」とエラー表示。

なお、上記 IAM ポリシーのとおり `s3:ListBucket` を付与していれば `HeadBucket` は 200 / 404 を返し、この `missingRequiredData` 経路には入らない（既存の自分のバケットは confirm 無しでそのまま使われる）。

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

### コード署名と Keychain entitlement（初回のみ Mac の登録が必要）

Tide は AWS 認証情報を **Data Protection Keychain**（`kSecUseDataProtectionKeychain=true`、セキュリティ対応 H1）に保存する。これを使うにはアプリに `keychain-access-groups` entitlement が必要で、`project.yml` の `entitlements` から `Tide/Tide.entitlements`（`$(AppIdentifierPrefix)org.izukawa.Tide`）が生成され署名に埋め込まれる。M5 Phase 2 からはこれに加えて **App Group entitlement**（`com.apple.security.application-groups` = `group.org.izukawa.Tide`）と **App Sandbox 一式**（`com.apple.security.app-sandbox` / `files.user-selected.read-write` / `network.client`）も署名に埋め込まれる（DB / 設定の置き場所が App Group コンテナになり、アプリ自体がサンドボックスで動くため）。automatic signing が App Group capability を App ID / プロファイルに反映できない場合は、Keychain と同様に初回だけ Xcode GUI でのビルドが要る。サンドボックス化後、同期フォルダへのアクセスは security-scoped bookmark で維持されていた（folderSync 世代。**v0.3.0 #97 以降の新規セットアップは bookmark を発行しない** — fpOnly に同期フォルダ面が無いため。再許可パネル等の解決系はデッド経路として温存・`files.user-selected.read-write` は設定 import/export・診断保存の panel 系で引き続き必要）。

automatic signing でこの entitlement を付与するには **Mac App Development プロビジョニングプロファイル**が要り、その生成には **この Mac が開発者アカウントにデバイス登録**されている必要がある。未登録だとビルドが
`Device "…" isn't registered in your developer account` で失敗し、実行時には Keychain 保存が `OSStatus 34018 (errSecMissingEntitlement)` になる。

- **初回だけ Xcode GUI で登録する**: `Tide.xcodeproj` を Xcode で開き、`Tide` ターゲットの Signing & Capabilities が team `G5G54TCH8W` / Automatically manage signing になっていることを確認して一度ビルド（⌘B）する。Xcode がこの Mac を自動登録し、開発用プロビジョニングプロファイルを作成する。
- 以後は CLI（`make build` / `make run` / `make test`）でも通る。`Makefile` の `xcodebuild` には **`-allowProvisioningUpdates`** を付けてあり、登録済みデバイス向けのプロファイル生成・更新を CLI から行えるようにしている（CLI 単体では未登録デバイスの新規登録はできない点に注意）。
- デバイス登録が上限（Mac は年間で消せない）に達している等で登録できない場合は、`docs`/会話で file ベース Keychain へのフォールバック可否を相談する。

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
- Subsystem: `org.izukawa.Tide`
- Process: `Tide`

コマンドラインなら:
```bash
log stream --predicate 'subsystem == "org.izukawa.Tide"' --level debug
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
defaults delete org.izukawa.Tide

# Keychain からも削除（手動で Keychain Access から、または）
security delete-generic-password -s org.izukawa.Tide
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
