package app

import (
	"context"
	"errors"
	"strings"
	"testing"

	"rabbithole/daemon/internal/uploader"
)

func TestRunnerResolvesFolderNameFromJobSettings(t *testing.T) {
	r, _, settings := failureRunner(t, fakeS3{})
	got, err := r.ResolveFolder(context.Background(), settings, "photos")
	if err != nil || got != "photos" {
		t.Fatalf("ResolveFolder = %q, %v", got, err)
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
