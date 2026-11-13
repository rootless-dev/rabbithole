package app

import (
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"syscall"

	"rabbithole/daemon/internal/logging"
)

// listenFunc opens a listener; net.Listen in production.
type listenFunc func(network, address string) (net.Listener, error)

// listenUnix creates the socket directory (mode 0700 even when it already
// existed), removes a stale file at path, listens on a Unix socket created
// with mode 0600 from the start, and returns the identity of the socket file
// this process created. The listener does not unlink the path on close: the
// caller removes it only if it is still the same file, so an exiting daemon
// never deletes a socket a newer daemon created at the same path.
func listenUnix(path string, listen listenFunc) (net.Listener, os.FileInfo, error) {
	if err := prepareSocketDir(path); err != nil {
		return nil, nil, err
	}

	// bind creates the socket file with the umask applied: 0177 yields 0600.
	oldMask := syscall.Umask(0o177)
	ln, err := listen("unix", path)
	syscall.Umask(oldMask)
	if err != nil {
		return nil, nil, fmt.Errorf("listen on %s: %w", path, err)
	}
	if unixLn, ok := ln.(*net.UnixListener); ok {
		unixLn.SetUnlinkOnClose(false)
	}

	info, err := restrictSocket(path)
	if err != nil {
		_ = ln.Close()
		return nil, nil, err
	}
	return ln, info, nil
}

// prepareSocketDir makes the directory of path private to the user and clears
// a stale socket file left at path.
func prepareSocketDir(path string) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return fmt.Errorf("create socket directory: %w", err)
	}
	if err := os.Chmod(dir, 0o700); err != nil {
		return fmt.Errorf("restrict socket directory permissions: %w", err)
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("remove stale socket: %w", err)
	}
	return nil
}

// restrictSocket sets the socket file to mode 0600, as a backstop for
// listeners that ignore the umask, and returns its identity.
func restrictSocket(path string) (os.FileInfo, error) {
	if err := os.Chmod(path, 0o600); err != nil {
		return nil, fmt.Errorf("restrict socket permissions: %w", err)
	}
	info, err := os.Stat(path)
	if err != nil {
		return nil, fmt.Errorf("stat socket: %w", err)
	}
	return info, nil
}

// removeOwnSocket removes path only if it is still the socket file this
// process created.
func removeOwnSocket(log *logging.Logger, path string, created os.FileInfo) {
	current, err := os.Lstat(path)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			log.Warn("could not inspect socket", "error", err.Error())
		}
		return
	}
	if !os.SameFile(created, current) {
		log.Info("socket was replaced; leaving it in place")
		return
	}
	if err := os.Remove(path); err != nil && !errors.Is(err, os.ErrNotExist) {
		log.Warn("could not remove socket", "error", err.Error())
	}
}
