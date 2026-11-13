package app

import (
	"context"
	"errors"
	"io"
	"slices"
	"strings"
	"testing"
	"time"

	"rabbithole/daemon/internal/logging"
	"rabbithole/daemon/internal/uploader"
)

// prefixRecorder is a fakeS3 that records the prefixes it is asked about.
type prefixRecorder struct {
	fakeS3
	prefixes *[]string
}

func (p prefixRecorder) PrefixExists(_ context.Context, prefix string) (bool, error) {
	*p.prefixes = append(*p.prefixes, prefix)
	return false, nil
}

func TestRunnerResolvesFolderNameFromJobSettings(t *testing.T) {
	want := uploader.Settings{AccessKeyID: "id", SecretAccessKey: "secret", Region: "r", Bucket: "b", Prefix: "quick/"}
	var prefixes []string
	var factorySettings []uploader.Settings
	r := &runner{
		uploader: uploader.New(time.Now),
		newS3: func(_ context.Context, s uploader.Settings) (uploader.S3, error) {
			factorySettings = append(factorySettings, s)
			return prefixRecorder{prefixes: &prefixes}, nil
		},
		log: logging.New(io.Discard, "info", serviceName),
	}

	got, err := r.ResolveFolder(context.Background(), want, "photos")
	if err != nil || got != "photos" {
		t.Fatalf("ResolveFolder = %q, %v", got, err)
	}
	if !slices.Equal(factorySettings, []uploader.Settings{want}) {
		t.Errorf("factory settings = %v, want [%v]", factorySettings, want)
	}
	if !slices.Equal(prefixes, []string{"quick/photos/"}) {
		t.Errorf("prefixes asked about = %v, want [quick/photos/]", prefixes)
	}
}

func TestFailedFolderResolutionLogsTheReasonWithoutCredentials(t *testing.T) {
	r, buf, settings := failureRunner(t, deniedListing{})
	_, err := r.ResolveFolder(context.Background(), settings, "photos")
	if !errors.Is(err, uploader.ErrForbidden) {
		t.Fatalf("err = %v, want ErrForbidden", err)
	}
	lines := logLines(t, buf.String())
	if len(lines) != 1 || lines[0]["msg"] != "folder name resolution failed" ||
		lines[0]["reason"] != uploader.Message(uploader.ErrForbidden) || lines[0]["file"] != "photos" {
		t.Fatalf("log lines = %v", lines)
	}
	if strings.Contains(buf.String(), leakTestSecret) || strings.Contains(buf.String(), leakTestKeyID) {
		t.Fatalf("log leaks a credential: %s", buf.String())
	}
}

// deniedListing is an S3 whose listings are denied.
type deniedListing struct{ fakeS3 }

func (deniedListing) PrefixExists(context.Context, string) (bool, error) {
	return false, uploader.ErrForbidden
}
