package awss3

import (
	"context"
	"errors"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"

	"rabbithole/daemon/internal/uploader"
)

const deleteResultOK = `<?xml version="1.0" encoding="UTF-8"?><DeleteResult></DeleteResult>`

func deleteResultWith(failures ...[2]string) string {
	var b strings.Builder
	b.WriteString(`<?xml version="1.0" encoding="UTF-8"?><DeleteResult>`)
	for _, f := range failures {
		fmt.Fprintf(&b, "<Error><Key>%s</Key><Code>%s</Code><Message>SECRET-TEXT</Message></Error>", f[0], f[1])
	}
	b.WriteString("</DeleteResult>")
	return b.String()
}

func TestDeleteObjectsPostsTheExactKeysInOneRequest(t *testing.T) {
	c, stub := newTestClient(t, func(*http.Request) *http.Response { return reply(200, deleteResultOK, nil) })

	deleted, err := c.DeleteObjects(context.Background(), []string{"quick/a.txt", "photos/b.jpg"})

	if err != nil || !slices.Equal(deleted, []string{"quick/a.txt", "photos/b.jpg"}) {
		t.Fatalf("deleted %v, err %v; want both keys", deleted, err)
	}
	reqs := stub.requests()
	if len(reqs) != 1 || reqs[0].Method != http.MethodPost || !reqs[0].URL.Query().Has("delete") {
		t.Fatalf("want a single POST ?delete request, got %d requests", len(reqs))
	}
	body := stub.lastBody()
	if !strings.Contains(body, "<Key>quick/a.txt</Key>") || !strings.Contains(body, "<Key>photos/b.jpg</Key>") {
		t.Fatalf("request body does not name the keys: %s", body)
	}
}

func TestDeleteObjectsReportsADeniedKeyAndKeepsTheRest(t *testing.T) {
	c, _ := newTestClient(t, func(*http.Request) *http.Response {
		return reply(200, deleteResultWith([2]string{"b", "AccessDenied"}), nil)
	})

	deleted, err := c.DeleteObjects(context.Background(), []string{"a", "b", "c"})

	if !errors.Is(err, uploader.ErrDeleteDenied) {
		t.Fatalf("err = %v, want ErrDeleteDenied", err)
	}
	if !slices.Equal(deleted, []string{"a", "c"}) {
		t.Fatalf("deleted = %v, want [a c]", deleted)
	}
	if strings.Contains(err.Error(), "SECRET-TEXT") {
		t.Fatalf("error carries the text S3 sent back: %v", err)
	}
}

func TestDeleteObjectsCountsAMissingKeyAsDeleted(t *testing.T) {
	c, _ := newTestClient(t, func(*http.Request) *http.Response {
		return reply(200, deleteResultWith([2]string{"a", "NoSuchKey"}), nil)
	})
	deleted, err := c.DeleteObjects(context.Background(), []string{"a"})
	if err != nil || !slices.Equal(deleted, []string{"a"}) {
		t.Fatalf("deleted %v, err %v; want [a], nil", deleted, err)
	}
}

func TestDeleteObjectsMapsAWholeRequestDenial(t *testing.T) {
	c, _ := newTestClient(t, func(*http.Request) *http.Response { return reply(403, errorXML("AccessDenied"), nil) })
	deleted, err := c.DeleteObjects(context.Background(), []string{"a"})
	if !errors.Is(err, uploader.ErrDeleteDenied) || len(deleted) != 0 {
		t.Fatalf("deleted %v, err %v; want nothing and ErrDeleteDenied", deleted, err)
	}
}

func TestDeleteObjectsRefusesMoreThanTheBatchLimit(t *testing.T) {
	c, stub := newTestClient(t, func(*http.Request) *http.Response { return reply(200, deleteResultOK, nil) })
	keys := make([]string, uploader.MaxDeleteBatch+1)
	for i := range keys {
		keys[i] = fmt.Sprint("k", i)
	}
	if _, err := c.DeleteObjects(context.Background(), keys); err == nil {
		t.Fatal("expected an error for an oversized batch")
	}
	if len(stub.requests()) != 0 {
		t.Fatal("an oversized batch must not reach S3")
	}
}

func TestListKeysFollowsEveryPage(t *testing.T) {
	c, stub := newTestClient(t, func(r *http.Request) *http.Response {
		if r.URL.Query().Get("continuation-token") == "" {
			return reply(200, strings.Replace(listXML("p/a", "p/b"), "<IsTruncated>false</IsTruncated>",
				"<IsTruncated>true</IsTruncated><NextContinuationToken>tok</NextContinuationToken>", 1), nil)
		}
		return reply(200, listXML("p/c"), nil)
	})

	var got []string
	err := c.ListKeys(context.Background(), "p/", func(k string) { got = append(got, k) })

	if err != nil || !slices.Equal(got, []string{"p/a", "p/b", "p/c"}) {
		t.Fatalf("keys %v, err %v; want p/a p/b p/c", got, err)
	}
	reqs := stub.requests()
	if len(reqs) != 2 || reqs[0].URL.Query().Get("prefix") != "p/" || reqs[1].URL.Query().Get("continuation-token") != "tok" {
		t.Fatalf("unexpected requests: %d", len(reqs))
	}
}

func TestListKeysMapsErrors(t *testing.T) {
	tests := []struct {
		name string
		code string
		want error
	}{
		{"denied", "AccessDenied", uploader.ErrForbidden},
		{"no bucket", "NoSuchBucket", uploader.ErrBucketNotFound},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			c, _ := newTestClient(t, func(*http.Request) *http.Response { return reply(403, errorXML(tt.code), nil) })
			err := c.ListKeys(context.Background(), "p/", func(string) {})
			if !errors.Is(err, tt.want) {
				t.Fatalf("err = %v, want %v", err, tt.want)
			}
		})
	}
}
