.PHONY: tools generate build test run

ROOT := $(CURDIR)
TOOLS_DIR := $(ROOT)/daemon/bin/tools
DAEMON_BIN := $(ROOT)/daemon/bin/rabbitholed

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

build:
	@if [ -d daemon/cmd/rabbitholed ]; then \
		cd daemon && go build -o $(DAEMON_BIN) ./cmd/rabbitholed; \
	else \
		echo "daemon build: not yet (cmd/rabbitholed lands in a later task)"; \
	fi
	@echo "app build: not yet (lands with Task 9)"

test:
	cd daemon && go test ./...
	@echo "app tests: not yet (lands with Task 9)"

run: build
	@echo "run: not yet (the app lands with Task 9)"
