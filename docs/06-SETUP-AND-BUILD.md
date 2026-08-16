# 開発環境セットアップとビルド

## 必要なもの

- macOS 26.0 (Tahoe) 以降
- Xcode 17 以降
- [xcodegen](https://github.com/yonaskolb/XcodeGen)（`Tide.xcodeproj` は `project.yml` から**毎回生成**する。`brew install xcodegen`）
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

セットアップウィザードは「バケットが存在しなければ作成しますか？」と尋ねる。アプリ内からバケットを作成するなら、上記とは別途、以下のステートメントを **アタッチして、初回作成後に剥がす** のが推奨運用:

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

### 正規手順は Makefile 経由

**ビルド・テスト・実行は Makefile を経由するのが基本**（`make help` で一覧）。`Tide.xcodeproj` は
xcodegen が `project.yml` から毎回生成するため、**直接編集しない**（Swift ファイルの追加 / 削除 /
リネーム後は `make generate` 必須。`make build` は generate を内包する）。

```bash
cd /path/to/Tide

make build      # xcodegen → Debug ビルド
make test       # ユニットテスト
make run        # ビルドして起動（run-ja / run-en で言語切替起動）
make fresh      # reset → build → 起動（新規セットアップ検証の定番）

# 生成物
ls ./build/Build/Products/Debug/Tide.app
```

### 生の xcodebuild を叩く場合（例外）

Makefile を使わず `xcodebuild` を直接叩くときは、以下のフラグが**必須**（Makefile はすべて内包している）:

```bash
xcodebuild -project Tide.xcodeproj \
           -scheme Tide \
           -configuration Debug \
           -derivedDataPath ./build \
           -destination 'platform=macOS,arch=arm64' \
           -skipPackagePluginValidation \
           -skipMacroValidation \
           -allowProvisioningUpdates
```

- `-skipPackagePluginValidation -skipMacroValidation`: aws-sdk-swift が依存する smithy-swift の
  ビルドプラグイン検証が CLI からは初回承認できないため（初回のみ Xcode GUI で
  SmithyCodeGeneratorPlugin の承認を求められる）。
- `-allowProvisioningUpdates`: Keychain / App Group entitlement のためのプロビジョニング
  プロファイル生成・更新を CLI から行うため（下記「コード署名」参照）。

### コード署名と Keychain entitlement（初回のみ Mac の登録が必要）

Tide は AWS 認証情報を **Data Protection Keychain**（`kSecUseDataProtectionKeychain=true`、セキュリティ対応 H1）に保存する。これを使うにはアプリに `keychain-access-groups` entitlement が必要で、`project.yml` の `entitlements` から `Tide/Tide.entitlements`（`$(AppIdentifierPrefix)org.izukawa.Tide`）が生成され署名に埋め込まれる。M5 Phase 2 からはこれに加えて **App Group entitlement**（`com.apple.security.application-groups` = **`G5G54TCH8W.org.izukawa.Tide`・チーム ID プレフィックス形式必須** — `group.org.izukawa.Tide` 形式は macOS では TCC 保護され、UI の無い File Provider 拡張が containermanagerd に拒否されるため。旧 `group.` 形式は `LegacyStateMigrator` の移行元としてアプリ側 entitlement にのみ残存）と **App Sandbox 一式**（`com.apple.security.app-sandbox` / `files.user-selected.read-write` / `network.client`）も署名に埋め込まれる（DB / 設定の置き場所が App Group コンテナになり、アプリ自体がサンドボックスで動くため）。**File Provider 拡張（`TideFileProvider.appex`・アプリの `PlugIns/` へ埋め込み）も同一 team・同一 App Group capability で署名される**必要がある（`project.yml` が両ターゲット分の entitlements を生成する）。automatic signing が App Group capability を App ID / プロファイルに反映できない場合は、Keychain と同様に初回だけ Xcode GUI でのビルドが要る。なお同期フォルダへの security-scoped bookmark は folderSync 世代の仕組みで、**v0.3.0 #97 以降の新規セットアップは bookmark を発行しない**（fpOnly に同期フォルダ面が無いため。再許可パネル等の解決系はデッド経路として温存・`files.user-selected.read-write` は設定 import/export・診断保存の panel 系で引き続き必要）。

automatic signing でこの entitlement を付与するには **Mac App Development プロビジョニングプロファイル**が要り、その生成には **この Mac が開発者アカウントにデバイス登録**されている必要がある。未登録だとビルドが
`Device "…" isn't registered in your developer account` で失敗し、実行時には Keychain 保存が `OSStatus 34018 (errSecMissingEntitlement)` になる。

- **初回だけ Xcode GUI で登録する**: `Tide.xcodeproj` を Xcode で開き、`Tide` ターゲットの Signing & Capabilities が team `G5G54TCH8W` / Automatically manage signing になっていることを確認して一度ビルド（⌘B）する。Xcode がこの Mac を自動登録し、開発用プロビジョニングプロファイルを作成する。
- 以後は CLI（`make build` / `make run` / `make test`）でも通る。`Makefile` の `xcodebuild` には **`-allowProvisioningUpdates`** を付けてあり、登録済みデバイス向けのプロファイル生成・更新を CLI から行えるようにしている（CLI 単体では未登録デバイスの新規登録はできない点に注意）。
- デバイス登録が上限（Mac は年間で消せない）に達している等で登録できない場合は、`docs`/会話で file ベース Keychain へのフォールバック可否を相談する。

### Xcode から

通常通り `cmd+R` で実行。

### リリースビルド & インストール

自分専用なので簡単に `~/Applications/` に置く（Release でも必須フラグは Debug と同じ）:

```bash
xcodegen generate
xcodebuild -project Tide.xcodeproj \
           -scheme Tide \
           -configuration Release \
           -derivedDataPath ./build \
           -destination 'platform=macOS,arch=arm64' \
           -skipPackagePluginValidation \
           -skipMacroValidation \
           -allowProvisioningUpdates

# ~/Applications に配置
rm -rf ~/Applications/Tide.app
cp -R ./build/Build/Products/Release/Tide.app ~/Applications/

# 起動
open ~/Applications/Tide.app
```

ローカルでビルドした .app は development 署名済みで quarantine 属性も付かないため、通常は
Gatekeeper に止められない（ネットワーク経由でコピーした場合のみ
`xattr -d com.apple.quarantine` が要ることがある）。

## 初回起動とセットアップ（fpOnly）

v0.3.0 以降、セットアップは **File Provider ネイティブ**（同期フォルダの選択は存在しない）。
ウィザードは 5 ステップ:

1. **AWS Credentials** — アクセスキー ID / シークレットアクセスキー（設定インポートもここ）
2. **Bucket** — リージョンを選択・バケット名を入力し「Test & Provision」（HeadBucket → 必要なら作成 confirm）
3. **Provisioning** — バージョニング / Public Access Block / ライフサイクル / TLS 強制ポリシーの適用結果
4. **Tide in Finder** — 同期の説明と FP ドメインの現況表示。「**Start syncing**」で設定保存 →
   FP ドメイン登録（= 同期の実体）→ signaler 起動まで一括実行
5. **Ready** — 完了

重要な点:

- **同期面は Finder サイドバー「場所」の Tide**（実体 `~/Library/CloudStorage/Tide-Tide`）。
  ファイルは dataless プレースホルダで列挙され、開いた瞬間に S3 からダウンロードされる。
  ローカル同期フォルダは作られない。
- **File Provider 拡張がシステム設定で OFF だと同期は無音で止まる**。ウィザードは
  fileProvider ステップで検出して警告 +「Open System Settings」ボタン
  （システム設定 >「ログイン項目と機能拡張」> ファイルプロバイダ）で誘導し、OFF のまま
  Start syncing しても post 検査で停止する。稼働中の OFF 化も検出してメニューバー表示 +
  通知で警告する（Issue #103）。
- **再セットアップ（バケット変更等）は FP ドメインの作り直し = 破壊的**。ウィザードが
  「This setup will recreate the Tide folder. Changes not yet uploaded will be discarded.」を
  表示する。未アップロードの変更は破棄されるため、必要なら先に退避する。

## 自動起動の設定

macOS のログイン項目に登録するには:

1. アプリ起動状態で `System Settings` > `General` > `Login Items`
2. `+` ボタンで `Tide.app` を追加

または、`SMAppService` API を使ってアプリ内から設定する機能を追加（M4 で検討）。

## デバッグ Tips

### ログの確認

Console.app で以下のフィルタ:
- Subsystem: `org.izukawa.Tide`

**同期の本体は `TideFileProvider` プロセス（FP 拡張）で動く**ため、Process を `Tide` に
絞ると肝心の同期ログが落ちる。subsystem は app / 拡張とも `org.izukawa.Tide` で共通なので、
subsystem フィルタだけで両プロセスを拾うのがよい。

コマンドラインなら:
```bash
log stream --predicate 'subsystem == "org.izukawa.Tide"' --level debug
```

Info ログは 10〜15 分で消えるため、事象が起きたら**即** `log show --last 10m …` で採取する。

### ローカル DB の確認（folderSync 世代・fpOnly では存在しない）

**v0.3.0（fpOnly）ではアプリは DB を開かず、新規セットアップでは `db.sqlite` は作られない**
（スキーマは folderSync 復帰資産としてコード温存 — `docs/03-LOCAL-DATABASE.md`）。
folderSync 世代の DB が残っている環境で覗く場合のパスは App Group コンテナ:

```bash
sqlite3 ~/Library/Group\ Containers/G5G54TCH8W.org.izukawa.Tide/Library/Application\ Support/Tide/db.sqlite
```

fpOnly の Sync Activity のデータ源は DB ではなく、FP 拡張が書く JSONL
（App Group コンテナの `Library/Caches/Tide/fp-events-ext.jsonl`）。

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
make reset   # ローカル状態を全消し
make fresh   # reset → build → 起動（新規セットアップ検証の定番）
```

`make reset` が消すもの: App Group コンテナ（DB / 設定の正位置・旧 `group.` 形式含む）・
App Sandbox コンテナ（標準 UserDefaults / Caches の実体）・実ホームの旧ロケーション残置分・
UserDefaults（`defaults delete` + `killall cfprefsd` = キャッシュ残り対策）・
Keychain エントリ（`security delete-generic-password` は 1 件ずつしか消せないためループで全件）。
手動で個別コマンドを叩くと消し漏れが出るので Makefile を使う。

注意:

- **FP ドメイン（`~/Library/CloudStorage/Tide-Tide`）は `make reset` では消えない**。
  再セットアップ時にウィザードがドメインを作り直す（破壊的 = 未アップロード変更は破棄・警告あり）。
- アプリ内 Settings の factory reset はサンドボックスから届く範囲のみ
  （実ホームの旧ロケーション残置分には届かない）。完全削除は `make reset`。

## 既知の落とし穴

### 1. FP 拡張がシステム設定で OFF だと同期が無音で止まる

FP ドメインの登録（`add(domain)`）自体は成功するのに、拡張が OFF だと fileproviderd が
拡張を起動せず**エラーなしで同期が止まる**。ウィザードの検出 / 誘導と稼働中の定期検知 +
通知（Issue #103）はあるが、開発中に「同期しない」と思ったらまずシステム設定 >
「ログイン項目と機能拡張」> ファイルプロバイダの Tide トグルを確認する。

### 2. FP ドメインの作り直しは破壊的

identifier スキーマ・ドメイン属性・item capabilities を変えたビルドへ切り替えた時は
**Disable → Enable でドメインを作り直す必要がある**（既存レプリカのキャッシュは自動更新
されない）。作り直しは S3 未到達の保留書込を**無警告で破棄する**ため、正規手順は
アプリ設定の Disable/Enable ボタン（`removeAllDomainsInvalidatingRegistries` 経由 =
レジストリ epoch リセット込み。素の `removeAllDomains` 直呼びは禁止 — Issue #104）。
システム設定のトグル OFF はレプリカを消さない（≠ Disable）。

### 3. 初回ビルドは Xcode GUI が必要

Keychain / App Group entitlement のプロビジョニングにこの Mac のデバイス登録が要る
（上記「コード署名」節）。CLI だけでは未登録デバイスの新規登録ができない。

### 4. Time Machine のスナップショットフォルダ

`.Spotlight-V100`、`.fseventsd`、`.Trashes` など、システムが管理する隠しフォルダは
`HardcodedIgnoreRules` で**除外実装済み**（`TideCore/Core/IgnoreRules.swift`）。
新しい「機密が紛れ込みそうな」dotfile / 拡張子を見つけたら即追加する（CLAUDE.md §3）。

## パッケージ更新

```bash
# Swift Package Manager の依存を最新化
xcodebuild -resolvePackageDependencies -project Tide.xcodeproj
```

Xcode 上では File > Packages > Update to Latest Package Versions。
