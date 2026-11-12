.PHONY: tools generate build test run daemon

ROOT := $(CURDIR)
TOOLS_DIR := $(ROOT)/daemon/bin/tools
DAEMON_BIN := $(ROOT)/daemon/bin/rabbitholed
XCODE_PROJECT := app/Rabbithole.xcodeproj
DERIVED_DATA := $(ROOT)/build/DerivedData

# Pinned Go protoc plugins, installed with the Go toolchain on PATH so they do
# not depend on a per-Go-version shim. The Swift plugins (protoc-gen-swift,
# protoc-gen-grpc-swift-2) come from Homebrew.
PROTOC_GEN_GO_VERSION := v1.36.11
PROTOC_GEN_GO_GRPC_VERSION := v1.6.2

tools:
	mkdir -p $(TOOLS_DIR)
	GOBIN=$(TOOLS_DIR) go install google.golang.org/protobuf/cmd/protoc-gen-go@$(PROTOC_GEN_GO_VERSION)
	GOBIN=$(TOOLS_DIR) go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@$(PROTOC_GEN_GO_GRPC_VERSION)

generate: tools
	cd proto && PATH="$(TOOLS_DIR):$$PATH" buf lint && PATH="$(TOOLS_DIR):$$PATH" buf generate

daemon:
	cd daemon && go build -o $(DAEMON_BIN) ./cmd/rabbitholed

build: daemon
	cd app && xcodegen generate
	xcodebuild -project $(XCODE_PROJECT) -scheme Rabbithole -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) build

test: daemon
	cd daemon && go test ./...
	cd app && xcodegen generate
	xcodebuild test -project $(XCODE_PROJECT) -scheme Rabbithole -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA)

run: build
	open $(DERIVED_DATA)/Build/Products/Debug/Rabbithole.app
