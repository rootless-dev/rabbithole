package download

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// errSave marks a failure of the local disk, as opposed to one of the bucket.
var errSave = errors.New("could not save the file")

// errIncomplete means the object ended before its announced size.
var errIncomplete = errors.New("the object ended before its size")

// fetch copies the object of f to its final path. The bytes go to a temporary
// file in the final directory, which is renamed when the copy is complete, so a
// partial file never sits under the real name. A failed or canceled copy
// leaves nothing behind. Nothing existing is overwritten.
func fetch(ctx context.Context, src Source, f plannedFile, progressed func(n int64)) (err error) {
	dir := filepath.Dir(f.final)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return fmt.Errorf("%w: %w", errSave, err)
	}
	if exists(f.final) {
		return fmt.Errorf("%w: the name is taken", errSave)
	}
	body, size, err := src.GetObject(ctx, f.key)
	if err != nil {
		return err
	}
	defer body.Close()

	tmp, err := os.CreateTemp(dir, ".rabbithole-*.part")
	if err != nil {
		return fmt.Errorf("%w: %w", errSave, err)
	}
	defer func() {
		if err != nil {
			_ = os.Remove(tmp.Name())
		}
	}()
	if err = copyBody(ctx, tmp, body, size, progressed); err != nil {
		return err
	}
	return place(tmp.Name(), f.final)
}

// copyBody writes body to tmp and closes it, checking that all of it arrived.
func copyBody(ctx context.Context, tmp *os.File, body io.Reader, size int64, progressed func(n int64)) error {
	written, copyErr := io.Copy(&countingWriter{w: tmp, onWrite: progressed}, ctxReader{ctx, body})
	closeErr := tmp.Close()
	switch {
	case copyErr != nil:
		return copyErr
	case closeErr != nil:
		return fmt.Errorf("%w: %w", errSave, closeErr)
	case size >= 0 && written != size:
		return fmt.Errorf("%w: got %d of %d bytes", errIncomplete, written, size)
	}
	return nil
}

// place renames the finished temporary file to its final name, with the mode
// of an ordinary file, unless something took that name in the meantime.
func place(tmp, final string) error {
	if err := os.Chmod(tmp, 0o644); err != nil {
		return fmt.Errorf("%w: %w", errSave, err)
	}
	// A hard link fails when the name exists, which makes "do not overwrite"
	// one atomic step instead of a check followed by a rename.
	switch err := os.Link(tmp, final); {
	case err == nil:
		_ = os.Remove(tmp)
		return nil
	case errors.Is(err, os.ErrExist):
		return fmt.Errorf("%w: the name is taken", errSave)
	}
	// The volume has no hard links: fall back to checking, then renaming.
	if exists(final) {
		return fmt.Errorf("%w: the name is taken", errSave)
	}
	if err := os.Rename(tmp, final); err != nil {
		return fmt.Errorf("%w: %w", errSave, err)
	}
	return nil
}

// countingWriter reports the bytes written and marks a write failure as a
// failure of the disk.
type countingWriter struct {
	w       io.Writer
	onWrite func(n int64)
}

func (c *countingWriter) Write(p []byte) (int, error) {
	n, err := c.w.Write(p)
	if n > 0 {
		c.onWrite(int64(n))
	}
	if err != nil {
		err = fmt.Errorf("%w: %w", errSave, err)
	}
	return n, err
}

// ctxReader fails reads once ctx has ended.
type ctxReader struct {
	ctx context.Context
	r   io.Reader
}

func (c ctxReader) Read(p []byte) (int, error) {
	if err := c.ctx.Err(); err != nil {
		return 0, err
	}
	return c.r.Read(p)
}
