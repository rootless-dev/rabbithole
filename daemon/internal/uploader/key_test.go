package uploader

import (
	"testing"
	"time"
)

func TestCandidateKey(t *testing.T) {
	now := time.Date(2026, 11, 12, 13, 10, 5, 0, time.Local)

	tests := []struct {
		name     string
		prefix   string
		fileName string
		attempt  int
		want     string
	}{
		{"attempt 0 is plain", "quick-uploads/", "report.pdf", 0, "quick-uploads/report.pdf"},
		{"attempt 1 is timestamped", "quick-uploads/", "report.pdf", 1, "quick-uploads/report-20261112-131005.pdf"},
		{"attempt 2 appends -2", "quick-uploads/", "report.pdf", 2, "quick-uploads/report-20261112-131005-2.pdf"},
		{"attempt 3 appends -3", "quick-uploads/", "report.pdf", 3, "quick-uploads/report-20261112-131005-3.pdf"},
		{"only the last extension is split", "quick-uploads/", "archive.tar.gz", 1, "quick-uploads/archive.tar-20261112-131005.gz"},
		{"no extension", "quick-uploads/", "Makefile", 1, "quick-uploads/Makefile-20261112-131005"},
		{"leading dot only is not an extension", "quick-uploads/", ".env", 1, "quick-uploads/.env-20261112-131005"},
		{"attempt 0 keeps unusual names unchanged", "quick-uploads/", "a b é.txt", 0, "quick-uploads/a b é.txt"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := CandidateKey(tt.prefix, tt.fileName, now, tt.attempt); got != tt.want {
				t.Errorf("CandidateKey(%q, %q, attempt %d) = %q, want %q", tt.prefix, tt.fileName, tt.attempt, got, tt.want)
			}
		})
	}
}
