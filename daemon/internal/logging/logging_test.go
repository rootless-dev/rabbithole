package logging

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"slices"
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

// emittedLevels logs one record at each level and returns the levels that came out.
func emittedLevels(t *testing.T, configured string) []string {
	t.Helper()
	var buf bytes.Buffer
	l := New(&buf, configured, "rabbitholed")
	l.Debug("m")
	l.Info("m")
	l.Warn("m")
	l.Error("m")

	var got []string
	for _, line := range strings.Split(strings.TrimSpace(buf.String()), "\n") {
		if line == "" {
			continue
		}
		got = append(got, parseLine(t, line)["level"].(string))
	}
	return got
}

func TestLevelNamesSelectWhichRecordsAreEmitted(t *testing.T) {
	all := []string{"debug", "info", "warn", "error"}
	tests := []struct {
		configured string
		want       []string
	}{
		{"debug", all},
		{"DEBUG", all},
		{"info", all[1:]},
		{"Info", all[1:]},
		{"warn", all[2:]},
		{"warning", all[2:]},
		{"WARNING", all[2:]},
		{"  warn  ", all[2:]},
		{"error", all[3:]},
		{"ERROR", all[3:]},
		{" Error\t", all[3:]},
		{"loud", all[1:]},
		{"", all[1:]},
		{"  ", all[1:]},
	}
	for _, tt := range tests {
		t.Run(fmt.Sprintf("%q", tt.configured), func(t *testing.T) {
			if got := emittedLevels(t, tt.configured); !slices.Equal(got, tt.want) {
				t.Errorf("level %q emitted %v, want %v", tt.configured, got, tt.want)
			}
		})
	}
}

func TestWarnLineHasContractFields(t *testing.T) {
	var buf bytes.Buffer
	New(&buf, "info", "rabbitholed").Warn("careful", "path", "/tmp/x")

	obj := parseLine(t, strings.TrimSpace(buf.String()))
	want := map[string]string{"level": "warn", "msg": "careful", "service": "rabbitholed", "path": "/tmp/x"}
	for k, v := range want {
		if obj[k] != v {
			t.Errorf("field %q = %v, want %q", k, obj[k], v)
		}
	}
	if _, ok := obj["time"]; !ok {
		t.Errorf("missing time field: %v", obj)
	}
}

func TestBootErrorWithoutAnErrorStillPrintsOneParseableLine(t *testing.T) {
	var buf bytes.Buffer
	BootError(&buf, "rabbitholed", nil)

	out := buf.String()
	if strings.Count(out, "\n") != 1 || !strings.HasSuffix(out, "\n") {
		t.Fatalf("want exactly one newline-terminated line, got %q", out)
	}
	obj := parseLine(t, strings.TrimSpace(out))
	if obj["level"] != "error" || obj["service"] != "rabbitholed" {
		t.Errorf("record = %v", obj)
	}
	if msg, _ := obj["msg"].(string); !strings.Contains(msg, "unknown boot error") {
		t.Errorf("msg = %v, want it to say the boot error is unknown", obj["msg"])
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
