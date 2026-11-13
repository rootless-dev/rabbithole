.PHONY: tools generate build test run daemon lint coverage daemon-universal package

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

# The old binary is removed first: go build refuses to overwrite the universal
# binary that `daemon-universal` leaves at the same path.
daemon:
	rm -f $(DAEMON_BIN)
	cd daemon && go build -o $(DAEMON_BIN) ./cmd/rabbitholed

build: daemon
	cd app && xcodegen generate
	xcodebuild -project $(XCODE_PROJECT) -scheme Rabbithole -configuration Debug \
		-derivedDataPath $(DERIVED_DATA) build

test: daemon
	cd daemon && go test -race ./...
	cd app && xcodegen generate
	xcodebuild test -project $(XCODE_PROJECT) -scheme Rabbithole -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA)

# Where `go install` puts binaries: GOBIN when it is set, otherwise GOPATH/bin.
GO_BIN_DIR := $(or $(shell go env GOBIN),$(shell go env GOPATH)/bin)
GOCYCLO := $(GO_BIN_DIR)/gocyclo
# The most branches a function of the daemon may have, tests aside.
MAX_COMPLEXITY := 10

# Static checks of the daemon: formatting, vet and cyclomatic complexity.
# gocyclo is installed with:
#   go install github.com/fzipp/gocyclo/cmd/gocyclo@v0.6.0
lint:
	@unformatted="$$(cd daemon && gofmt -l cmd internal)"; \
		if [ -n "$$unformatted" ]; then echo "gofmt needed on:"; echo "$$unformatted"; exit 1; fi
	cd daemon && go vet ./...
	@complex="$$(cd daemon && $(GOCYCLO) -over $(MAX_COMPLEXITY) cmd internal | grep -v -e '_test\.go' -e 'internal/gen/' || true)"; \
		if [ -n "$$complex" ]; then echo "functions over complexity $(MAX_COMPLEXITY):"; echo "$$complex"; exit 1; fi

COVERAGE_DIR := $(ROOT)/build/coverage

# Runs both test suites with coverage and prints the totals. The Go profile
# leaves out the generated gRPC code. Reports are written under build/coverage.
coverage: daemon
	rm -rf $(COVERAGE_DIR) && mkdir -p $(COVERAGE_DIR)
	cd daemon && go test -coverprofile=$(COVERAGE_DIR)/go.out $$(go list ./... | grep -v /internal/gen/)
	cd daemon && go tool cover -func=$(COVERAGE_DIR)/go.out > $(COVERAGE_DIR)/go.txt
	cd app && xcodegen generate
	xcodebuild test -project $(XCODE_PROJECT) -scheme Rabbithole -configuration Debug \
		-destination 'platform=macOS' -derivedDataPath $(DERIVED_DATA) \
		-enableCodeCoverage YES -resultBundlePath $(COVERAGE_DIR)/app.xcresult
	xcrun xccov view --report --only-targets $(COVERAGE_DIR)/app.xcresult > $(COVERAGE_DIR)/app.txt
	@echo "Go:    $$(tail -1 $(COVERAGE_DIR)/go.txt | awk '{print $$NF}') of statements"
	@cat $(COVERAGE_DIR)/app.txt

# Builds the daemon for Apple silicon and Intel in one binary, so a packaged
# app runs on both.
daemon-universal:
	cd daemon && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o $(DAEMON_BIN)-arm64 ./cmd/rabbitholed
	cd daemon && CGO_ENABLED=0 GOOS=darwin GOARCH=amd64 go build -trimpath -o $(DAEMON_BIN)-amd64 ./cmd/rabbitholed
	lipo -create -output $(DAEMON_BIN) $(DAEMON_BIN)-arm64 $(DAEMON_BIN)-amd64
	rm -f $(DAEMON_BIN)-arm64 $(DAEMON_BIN)-amd64

RELEASE_APP := $(DERIVED_DATA)/Build/Products/Release/Rabbithole.app
PACKAGE := $(ROOT)/build/Rabbithole.zip

# Builds the app in Release with the universal daemon inside and zips it to
# build/Rabbithole.zip. The app is signed ad hoc, not notarized.
package: daemon-universal
	cd app && xcodegen generate
	xcodebuild -project $(XCODE_PROJECT) -scheme Rabbithole -configuration Release \
		-derivedDataPath $(DERIVED_DATA) build
	rm -f $(PACKAGE)
	ditto -c -k --keepParent $(RELEASE_APP) $(PACKAGE)
	@echo "Packaged $(PACKAGE)"

# Runs the app in the foreground so the daemon's JSON logs appear in this
# terminal and the target ends when the app quits. `open` would send the logs
# nowhere and could bring forward a stale instance, so a running one is quit first.
run: build
	pkill -x Rabbithole || true
	sleep 2
	$(DERIVED_DATA)/Build/Products/Debug/Rabbithole.app/Contents/MacOS/Rabbithole
