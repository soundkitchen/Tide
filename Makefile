# Tide development helpers.
# `make help` で全ターゲットを表示。

SHELL      := /bin/bash
APP_NAME   := Tide
BUNDLE_ID  := org.izukawa.Tide
SCHEME     := $(APP_NAME)
PROJECT    := $(APP_NAME).xcodeproj
APP_PATH   := build/Build/Products/Debug/$(APP_NAME).app
SUPPORT    := $(HOME)/Library/Application Support/$(APP_NAME)
CACHES     := $(HOME)/Library/Caches/$(APP_NAME)
# App Group コンテナ（M5 Phase 2 以降の DB / 設定の正位置。Phase 3 でチーム ID プレフィックス形式へ）
GROUP_ID            := G5G54TCH8W.org.izukawa.Tide
GROUP_CONTAINER     := $(HOME)/Library/Group Containers/$(GROUP_ID)
# Phase 2 で一時使用した旧 group. 形式コンテナ（移行元。reset では一緒に消す）
OLD_GROUP_ID        := group.org.izukawa.Tide
OLD_GROUP_CONTAINER := $(HOME)/Library/Group Containers/$(OLD_GROUP_ID)
# App Sandbox コンテナ（M5 Phase 2 以降、Caches / 標準 UserDefaults はここに解決される）
APP_CONTAINER   := $(HOME)/Library/Containers/$(BUNDLE_ID)

XCODEBUILD := xcodebuild \
	-project $(PROJECT) \
	-scheme $(SCHEME) \
	-configuration Debug \
	-derivedDataPath ./build \
	-destination 'platform=macOS,arch=arm64' \
	-skipPackagePluginValidation \
	-skipMacroValidation \
	-allowProvisioningUpdates

.DEFAULT_GOAL := help

# ────────────────────────────────────────────
# Help

.PHONY: help
help: ## 利用可能なターゲット一覧
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

# ────────────────────────────────────────────
# Reset (ローカル状態のクリア)

.PHONY: reset
reset: stop ## ローカル設定をリセット（App Group + Sandbox コンテナ + Application Support + UserDefaults + Keychain + Caches）
	rm -rf "$(GROUP_CONTAINER)"
	rm -rf "$(OLD_GROUP_CONTAINER)"
	rm -rf "$(APP_CONTAINER)"
	rm -rf "$(SUPPORT)"
	rm -rf "$(CACHES)"
	-defaults delete $(BUNDLE_ID) 2>/dev/null
	@# group suite の plist は group container ごと消したが、cfprefsd のキャッシュに残った値が
	@# 次回起動で読めてしまうことがあるので明示的に落とす（自動で再起動される）。
	-killall cfprefsd 2>/dev/null
	@# `-s` で 1 件ずつ削除しかできないので、無くなるまで繰り返す
	@while security delete-generic-password -s $(BUNDLE_ID) >/dev/null 2>&1; do :; done
	@echo "✓ Cleared: $(GROUP_CONTAINER)"
	@echo "✓ Cleared: $(APP_CONTAINER)"
	@echo "✓ Cleared: $(SUPPORT)"
	@echo "✓ Cleared: $(CACHES)"
	@echo "✓ Cleared: UserDefaults($(BUNDLE_ID) / $(GROUP_ID))"
	@echo "✓ Cleared: Keychain entries (service=$(BUNDLE_ID))"

.PHONY: stop
stop: ## 稼働中の Tide を終了
	-@pkill -x $(APP_NAME) 2>/dev/null && echo "stopped" || echo "(not running)"
	@sleep 1

# ────────────────────────────────────────────
# Build / Run / Test

.PHONY: generate
generate: ## xcodegen で Tide.xcodeproj を生成
	xcodegen generate

.PHONY: build
build: generate ## Debug ビルド
	$(XCODEBUILD) build

.PHONY: test
test: generate ## ユニットテスト実行
	$(XCODEBUILD) test

.PHONY: run
run: build ## ビルドして起動
	open $(APP_PATH)

.PHONY: run-ja
run-ja: build ## 日本語ロケールで起動
	open $(APP_PATH) --args -AppleLanguages '(ja)' -AppleLocale ja_JP

.PHONY: run-en
run-en: build ## 英語ロケールで起動
	open $(APP_PATH) --args -AppleLanguages '(en)' -AppleLocale en_US

.PHONY: fresh
fresh: reset run ## reset してから起動（新規セットアップのテストに）

.PHONY: soak-check
soak-check: ## soak 整合性突合: 同期フォルダ ↔ DB ↔ S3 マニフェスト ↔ S3 実体（#40）
	python3 tools/soak/consistency_check.py

.PHONY: soak-watch
soak-watch: ## soak 常時観測: consistency_check を 300 秒間隔で回し JSONL 追記（#40）
	python3 tools/soak/consistency_check.py --watch 300

.PHONY: soak-check-fp
soak-check-fp: ## soak 整合性突合（FP-only スコープ: S3 面のみ・凍結 DB/フォルダ非突合）（#40）
	python3 tools/soak/consistency_check.py --fp-only

.PHONY: soak-watch-fp
soak-watch-fp: ## soak 常時観測（FP-only スコープ）: 300 秒間隔で JSONL 追記（#40）
	python3 tools/soak/consistency_check.py --fp-only --watch 300

.PHONY: soak-churn
soak-churn: ## soak 負荷注入: FSEvents/FP 両サイドへ create/edit/rename/delete 等を交錯注入（#40）
	python3 tools/soak/churn.py

.PHONY: clean
clean: stop ## build/ を削除
	rm -rf build/
