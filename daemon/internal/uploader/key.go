package uploader

import (
	"fmt"
	"path/filepath"
	"time"
)

const keyTimestampLayout = "20060102-150405"

// CandidateKey returns the object key to try for the given attempt.
// Attempt 0 is the plain name, attempt 1 inserts a local-time timestamp before
// the extension, and attempt n >= 2 appends "-n" to that timestamp.
func CandidateKey(prefix, fileName string, now time.Time, attempt int) string {
	if attempt <= 0 {
		return prefix + fileName
	}

	ext := filepath.Ext(fileName)
	if ext == fileName {
		// The only dot is the leading one (".env"), so there is no extension.
		ext = ""
	}
	base := fileName[:len(fileName)-len(ext)]

	stamp := now.Local().Format(keyTimestampLayout)
	if attempt >= 2 {
		stamp = fmt.Sprintf("%s-%d", stamp, attempt)
	}
	return prefix + base + "-" + stamp + ext
}
