package uploader

import (
	"context"
	"errors"
	"fmt"
	"slices"
	"testing"
	"time"
)

func TestCandidateFolderName(t *testing.T) {
	now := time.Date(2026, 11, 12, 13, 10, 5, 0, time.Local)
	tests := []struct {
		name    string
		folder  string
		attempt int
		want    string
	}{
		{"attempt 0 is plain", "photos", 0, "photos"},
		{"attempt 1 is timestamped", "photos", 1, "photos-20261112-131005"},
		{"attempt 2 appends -2", "photos", 2, "photos-20261112-131005-2"},
		{"a dot is not an extension", "v1.2", 1, "v1.2-20261112-131005"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := CandidateFolderName(tt.folder, now, tt.attempt); got != tt.want {
				t.Errorf("got %q, want %q", got, tt.want)
			}
		})
	}
}

func TestResolveFolderUsesPlainNameWhenFree(t *testing.T) {
	fake := newFake("p/other/a.txt")
	got, err := newUploader().ResolveFolder(context.Background(), fake, "p/", "photos")
	if err != nil {
		t.Fatal(err)
	}
	if got != "photos" || !slices.Equal(fake.prefixes, []string{"p/photos/"}) {
		t.Errorf("got %q after checking %v", got, fake.prefixes)
	}
}

func TestResolveFolderSkipsTakenNames(t *testing.T) {
	taken := CandidateFolderName("photos", fixedNow, 1)
	fake := newFake("p/photos/a.txt", "p/"+taken+"/b.txt")
	got, err := newUploader().ResolveFolder(context.Background(), fake, "p/", "photos")
	if err != nil {
		t.Fatal(err)
	}
	if want := CandidateFolderName("photos", fixedNow, 2); got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveFolderDoesNotMistakeASiblingPrefixForTheFolder(t *testing.T) {
	// "photos-old/" starts with "photos" but not with "photos/".
	fake := newFake("p/photos-old/a.txt")
	got, err := newUploader().ResolveFolder(context.Background(), fake, "p/", "photos")
	if err != nil || got != "photos" {
		t.Errorf("got %q, %v", got, err)
	}
}

func TestResolveFolderReportsDeniedListing(t *testing.T) {
	fake := newFake()
	fake.existsErr = fmt.Errorf("list: %w", ErrForbidden)
	_, err := newUploader().ResolveFolder(context.Background(), fake, "p/", "photos")
	if !errors.Is(err, ErrForbidden) || !IsFatal(err) {
		t.Errorf("err = %v, want fatal ErrForbidden", err)
	}
}

func TestSkipExistenceCheckGoesStraightToThePut(t *testing.T) {
	path := sparseFile(t, "a.txt", 10)
	fake := newFake()
	rec := &recorder{}
	req := Request{Prefix: "p/photos/", LocalPath: path, SkipExistenceCheck: true}
	if err := newUploader().Upload(context.Background(), fake, req, rec.callbacks()); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.calls, []string{"put"}) || !slices.Equal(fake.putKeys, []string{"p/photos/a.txt"}) {
		t.Errorf("calls = %v, keys = %v", fake.calls, fake.putKeys)
	}
}

func TestSkipExistenceCheckStillFallsBackWhenTheWriteIsRejected(t *testing.T) {
	path := sparseFile(t, "a.txt", 10)
	fake := newFake()
	fake.putErr = func(key string) error {
		if key == "p/photos/a.txt" {
			return fmt.Errorf("put: %w", ErrPreconditionFailed)
		}
		return nil
	}
	req := Request{Prefix: "p/photos/", LocalPath: path, SkipExistenceCheck: true}
	if err := newUploader().Upload(context.Background(), fake, req, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	want := CandidateKey("p/photos/", "a.txt", fixedNow, 1)
	if !slices.Equal(fake.putKeys, []string{"p/photos/a.txt", want}) {
		t.Errorf("put keys = %v", fake.putKeys)
	}
}

func TestSkipExistenceCheckKeepsTheCheckForMultipart(t *testing.T) {
	path := sparseFile(t, "big.bin", 16<<20)
	fake := newFake()
	req := Request{Prefix: "p/photos/", LocalPath: path, SkipExistenceCheck: true}
	if err := newUploader().Upload(context.Background(), fake, req, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if len(fake.calls) == 0 || fake.calls[0] != "exists" {
		t.Errorf("calls = %v, want the existence check first", fake.calls)
	}
}

func TestRequestNameOverridesTheFileName(t *testing.T) {
	path := sparseFile(t, "a.txt", 10)
	fake := newFake()
	if err := newUploader().Upload(context.Background(), fake, Request{Prefix: "p/", LocalPath: path, Name: "a-2.txt"}, Callbacks{}); err != nil {
		t.Fatal(err)
	}
	if !slices.Equal(fake.putKeys, []string{"p/a-2.txt"}) {
		t.Errorf("put keys = %v", fake.putKeys)
	}
}

func TestIsFatal(t *testing.T) {
	fatal := []error{ErrBadCredentials, ErrBucketNotFound, ErrBucketInaccessible, ErrWrongRegion, ErrNoNetwork, ErrForbidden, ErrWriteDenied}
	for _, err := range fatal {
		if !IsFatal(fmt.Errorf("wrapped: %w", err)) {
			t.Errorf("%v should be fatal", err)
		}
	}
	for _, err := range []error{ErrFileUnreadable, ErrPreconditionFailed, ErrNoFreeName, context.Canceled, errors.New("boom")} {
		if IsFatal(err) {
			t.Errorf("%v should not be fatal", err)
		}
	}
}
