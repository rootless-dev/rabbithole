package buckets

import (
	"errors"
	"fmt"
	"strings"
	"testing"

	"rabbithole/daemon/internal/uploader"
)

func TestValidateName(t *testing.T) {
	tests := []struct {
		name string
		ok   bool
	}{
		{"abc", true},
		{"my-backups-2026", true},
		{"a1b", true},
		{strings.Repeat("a", 63), true},
		{strings.Repeat("a", 64), false},
		{"ab", false},
		{"", false},
		{"-abc", false},
		{"abc-", false},
		{"My-Bucket", false},
		{"my_bucket", false},
		{"my.bucket", false},
		{"my bucket", false},
		{"bücket", false},
		{"abc\n", false},
	}
	for _, tt := range tests {
		err := ValidateName(tt.name)
		if tt.ok && err != nil || !tt.ok && !errors.Is(err, ErrInvalidName) {
			t.Errorf("ValidateName(%q) = %v, want ok=%v", tt.name, err, tt.ok)
		}
	}
}

func TestCreateMessageUsesTheTextsOfTheDesign(t *testing.T) {
	tests := []struct {
		err  error
		want string
	}{
		{ErrNameTaken, "This name is already taken by another AWS account. Bucket names are unique in all of AWS: try another one."},
		{ErrOwnedByYou, "You already have a bucket with this name. Choose it in the list instead."},
		{ErrInvalidName, "This name is not valid. Use 3 to 63 lowercase letters, numbers and hyphens, starting and ending with a letter or a number."},
		{ErrCreateDenied, "AWS denied permission to create buckets: the access key needs the s3:CreateBucket permission"},
		{fmt.Errorf("wrapped: %w", uploader.ErrBadCredentials), "AWS rejected the access key"},
		{uploader.ErrNoNetwork, "No internet connection"},
		{ErrTooManyBucket, "This account has reached its limit of buckets"},
		{errors.New("something else"), "The bucket could not be created"},
	}
	for _, tt := range tests {
		if got := CreateMessage(tt.err); got != tt.want {
			t.Errorf("CreateMessage(%v) = %q, want %q", tt.err, got, tt.want)
		}
	}
}

func TestCredentialsAreRedactedWhenPrinted(t *testing.T) {
	c := Credentials{AccessKeyID: "AKIDSECRET", SecretAccessKey: "topsecret", Region: "eu-west-1"}
	for _, s := range []string{fmt.Sprint(c), fmt.Sprintf("%+v", c), fmt.Sprintf("%#v", c)} {
		if strings.Contains(s, "AKIDSECRET") || strings.Contains(s, "topsecret") {
			t.Fatalf("%q leaks a credential", s)
		}
	}
}
