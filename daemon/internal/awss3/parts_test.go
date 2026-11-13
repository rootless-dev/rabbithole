package awss3

import (
	"context"
	"errors"
	"net/http"
	"reflect"
	"strconv"
	"testing"

	"rabbithole/daemon/internal/uploader"
)

func partsXML(truncated bool, next int, parts ...[3]any) string {
	out := `<?xml version="1.0" encoding="UTF-8"?><ListPartsResult><Bucket>my-bucket</Bucket><Key>k</Key><UploadId>up-1</UploadId>`
	if truncated {
		out += "<IsTruncated>true</IsTruncated>"
	} else {
		out += "<IsTruncated>false</IsTruncated>"
	}
	if next > 0 {
		out += "<NextPartNumberMarker>" + itoa(next) + "</NextPartNumberMarker>"
	}
	for _, p := range parts {
		out += "<Part><PartNumber>" + itoa(p[0].(int)) + "</PartNumber><ETag>" + p[1].(string) + "</ETag><Size>" + itoa(p[2].(int)) + "</Size></Part>"
	}
	return out + "</ListPartsResult>"
}

func itoa(n int) string { return strconv.Itoa(n) }

func TestListPartsFollowsEveryPage(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response {
		if r.URL.Query().Get("part-number-marker") == "2" {
			return reply(200, partsXML(false, 0, [3]any{3, `"e3"`, 7}), nil)
		}
		return reply(200, partsXML(true, 2, [3]any{1, `"e1"`, 8388608}, [3]any{2, `"e2"`, 8388608}), nil)
	})

	got, err := c.ListParts(context.Background(), "k", "up-1")
	if err != nil {
		t.Fatal(err)
	}
	want := []uploader.HeldPart{{Number: 1, ETag: `"e1"`, Size: 8388608}, {Number: 2, ETag: `"e2"`, Size: 8388608}, {Number: 3, ETag: `"e3"`, Size: 7}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("parts = %+v, want %+v", got, want)
	}
	reqs := stub.requests()
	if len(reqs) != 2 || reqs[0].URL.Query().Get("uploadId") != "up-1" {
		t.Fatalf("requests = %d, want two pages for upload up-1", len(reqs))
	}
}

func TestListPartsMapsErrors(t *testing.T) {
	cases := []struct {
		name   string
		status int
		code   string
		want   error
	}{
		{"denied", 403, "AccessDenied", uploader.ErrListPartsDenied},
		{"unknown upload", 404, "NoSuchUpload", uploader.ErrNoSuchUpload},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			c, _ := newTestClient(t, func(r *http.Request) *http.Response { return reply(tc.status, errorXML(tc.code), nil) })
			_, err := c.ListParts(context.Background(), "k", "up-1")
			if !errors.Is(err, tc.want) {
				t.Fatalf("err = %v, want %v", err, tc.want)
			}
			if uploader.IsFatal(err) {
				t.Fatalf("%v must not be fatal", err)
			}
		})
	}
}
