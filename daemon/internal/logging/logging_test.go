package logging

import (
	"bytes"
	"encoding/json"
	"errors"
	"strings"
	"testing"
)

func parseLine(t *testing.T, line string) map[string]any {
	t.Helper()
	var obj map[string]any
	if err := json.Unmarshal([]byte(line), &obj); err != nil {
		t.Fatalf("output is not valid JSON: %q: %v", line, err)
	}
	return obj
}

func TestInfoLineHasContractFields(t *testing.T) {
	var buf bytes.Buffer
	New(&buf, "info", "rabbitholed").Info("hello", "upload_id", "u1")

	obj := parseLine(t, strings.TrimSpace(buf.String()))
	if _, ok := obj["time"]; !ok {
		t.Errorf("missing time field: %v", obj)
	}
	want := map[string]string{
		"level":     "info",
		"msg":       "hello",
		"service":   "rabbitholed",
		"upload_id": "u1",
	}
	for k, v := range want {
		if obj[k] != v {
			t.Errorf("field %q = %v, want %q", k, obj[k], v)
		}
	}
}

func TestUnknownLevelFallsBackToInfo(t *testing.T) {
	for _, level := range []string{"loud", ""} {
		var buf bytes.Buffer
		l := New(&buf, level, "rabbitholed")

		l.Debug("x")
		if buf.Len() != 0 {
			t.Errorf("level %q: Debug wrote %q, want nothing", level, buf.String())
		}

		l.Info("x")
		lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
		if len(lines) != 1 || lines[0] == "" {
			t.Errorf("level %q: Info wrote %d lines, want 1: %q", level, len(lines), buf.String())
		}
	}
}

func TestDebugLevelEnablesDebug(t *testing.T) {
	var buf bytes.Buffer
	New(&buf, "debug", "rabbitholed").Debug("x")

	obj := parseLine(t, strings.TrimSpace(buf.String()))
	if obj["level"] != "debug" {
		t.Errorf("level = %v, want debug", obj["level"])
	}
}

func TestBootErrorPrintsOneParseableLine(t *testing.T) {
	var buf bytes.Buffer
	BootError(&buf, "rabbitholed", errors.New("bad config"))

	out := buf.String()
	if strings.Count(out, "\n") != 1 || !strings.HasSuffix(out, "\n") {
		t.Fatalf("want exactly one newline-terminated line, got %q", out)
	}
	obj := parseLine(t, strings.TrimSpace(out))
	if obj["level"] != "error" {
		t.Errorf("level = %v, want error", obj["level"])
	}
	if msg, _ := obj["msg"].(string); !strings.Contains(msg, "bad config") {
		t.Errorf("msg = %v, want it to contain the error text", obj["msg"])
	}
	if obj["service"] != "rabbitholed" {
		t.Errorf("service = %v, want rabbitholed", obj["service"])
	}
	if _, ok := obj["time"]; !ok {
		t.Errorf("missing time field: %v", obj)
	}
}
