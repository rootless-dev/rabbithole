// Package logging provides the daemon's structured JSON logger. The underlying
// library is an implementation detail and none of its types are exposed.
//
// Every record is one JSON line with the fields time, level, msg and service,
// plus any caller-supplied key/value pairs.
package logging

import (
	"errors"
	"io"
	"strings"

	"github.com/phuslu/log"
)

func init() {
	// phuslu names the message field "message" by default; the output contract
	// requires "msg". MessageKey is the library's supported (package-wide) option.
	log.MessageKey = "msg"
}

// Logger writes structured JSON log lines.
type Logger struct {
	inner *log.Logger
}

// New returns a Logger that writes JSON lines to w, tagged with service.
// level is one of debug, info, warn or error (case-insensitive); any other
// value falls back to info so that a typo never silences the service.
func New(w io.Writer, level string, service string) *Logger {
	return &Logger{inner: &log.Logger{
		Level:   parseLevel(level),
		Context: log.NewContext(nil).Str("service", service).Value(),
		Writer:  &log.IOWriter{Writer: w},
	}}
}

// BootError writes a single error line to w and returns. It is meant for
// failures that happen before the configured logger exists, such as invalid
// configuration, so that log collectors still receive a parseable record.
func BootError(w io.Writer, service string, err error) {
	if err == nil {
		err = errors.New("unknown boot error")
	}
	New(w, "error", service).Error("boot failed: " + err.Error())
}

// Debug logs msg at debug level. kv holds alternating keys and values.
func (l *Logger) Debug(msg string, kv ...any) { l.inner.Debug().KeysAndValues(kv...).Msg(msg) }

// Info logs msg at info level. kv holds alternating keys and values.
func (l *Logger) Info(msg string, kv ...any) { l.inner.Info().KeysAndValues(kv...).Msg(msg) }

// Warn logs msg at warn level. kv holds alternating keys and values.
func (l *Logger) Warn(msg string, kv ...any) { l.inner.Warn().KeysAndValues(kv...).Msg(msg) }

// Error logs msg at error level. kv holds alternating keys and values.
func (l *Logger) Error(msg string, kv ...any) { l.inner.Error().KeysAndValues(kv...).Msg(msg) }

func parseLevel(s string) log.Level {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "debug":
		return log.DebugLevel
	case "warn", "warning":
		return log.WarnLevel
	case "error":
		return log.ErrorLevel
	default:
		return log.InfoLevel
	}
}
