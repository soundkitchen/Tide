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
# App Group コンテナ（M5 Phase 2 以降の DB / 設定の正位置）
GROUP_ID        := group.org.izukawa.Tide
GROUP_CONTAINER := $(HOME)/Library/Group Containers/$(GROUP_ID)
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

.PHONY: clean
clean: stop ## build/ を削除
	rm -rf build/
