package uploader

import (
	"fmt"
	"path/filepath"
	"time"
)

const keyTimestampLayout = "20060102-150405"

// Ext returns the extension of a file name, dot included. A name whose only
// dot is the leading one (".env") has no extension.
func Ext(name string) string {
	ext := filepath.Ext(name)
	if ext == name {
		return ""
	}
	return ext
}

// candidateSuffix is what the given attempt adds to a name: a local-time
// timestamp, followed by "-n" for attempt n >= 2.
func candidateSuffix(now time.Time, attempt int) string {
	stamp := now.Local().Format(keyTimestampLayout)
	if attempt >= 2 {
		stamp = fmt.Sprintf("%s-%d", stamp, attempt)
	}
	return "-" + stamp
}

// CandidateFolderName returns the folder name to try for the given attempt:
// the plain name, then name-<stamp>, then name-<stamp>-n for n >= 2. Unlike
// CandidateKey it never treats a dot in the name as an extension.
func CandidateFolderName(name string, now time.Time, attempt int) string {
	if attempt <= 0 {
		return name
	}
	return name + candidateSuffix(now, attempt)
}

// CandidateKey returns the object key to try for the given attempt.
// Attempt 0 is the plain name, attempt 1 inserts a local-time timestamp before
// the extension, and attempt n >= 2 appends "-n" to that timestamp.
func CandidateKey(prefix, fileName string, now time.Time, attempt int) string {
	if attempt <= 0 {
		return prefix + fileName
	}
	ext := Ext(fileName)
	base := fileName[:len(fileName)-len(ext)]
	return prefix + base + candidateSuffix(now, attempt) + ext
}
