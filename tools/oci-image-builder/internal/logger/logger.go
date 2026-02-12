// Package logger provides a shared logging interface for oci-image-builder components.
package logger

import "fmt"

// Logger provides a simple logging interface that can be configured
// to send log messages to different destinations (TUI, stdout, etc.).
type Logger struct {
	logFn func(string)
}

// New creates a new Logger with a no-op log function.
func New() *Logger {
	return &Logger{
		logFn: func(string) {},
	}
}

// SetLogFunc sets the function used to output log messages.
func (l *Logger) SetLogFunc(fn func(string)) {
	if fn == nil {
		l.logFn = func(string) {}
	} else {
		l.logFn = fn
	}
}

// Log outputs a message through the configured log function.
func (l *Logger) Log(msg string) {
	l.logFn(msg)
}

// Logf outputs a formatted message through the configured log function.
func (l *Logger) Logf(format string, args ...interface{}) {
	l.logFn(fmt.Sprintf(format, args...))
}
