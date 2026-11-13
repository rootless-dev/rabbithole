package history

import (
	"database/sql"
	"encoding/json"
	"fmt"

	"rabbithole/daemon/internal/queue"
	"rabbithole/daemon/internal/uploader"
)

// storedPart is a completed part as it is kept in the parts column.
type storedPart struct {
	Number int32  `json:"number"`
	ETag   string `json:"etag"`
}

func encodeParts(parts []uploader.CompletedPart) (string, error) {
	out := make([]storedPart, len(parts))
	for i, p := range parts {
		out[i] = storedPart{Number: p.Number, ETag: p.ETag}
	}
	b, err := json.Marshal(out)
	if err != nil {
		return "", fmt.Errorf("encode parts: %w", err)
	}
	return string(b), nil
}

func decodeParts(text string) ([]uploader.CompletedPart, error) {
	var stored []storedPart
	if err := json.Unmarshal([]byte(text), &stored); err != nil {
		return nil, fmt.Errorf("decode parts: %w", err)
	}
	out := make([]uploader.CompletedPart, len(stored))
	for i, p := range stored {
		out[i] = uploader.CompletedPart{Number: p.Number, ETag: p.ETag}
	}
	return out, nil
}

// saveMultiparts applies the changes to the multipart records. A record is
// stored only for a file that exists; clearing one that is absent is a no-op.
func saveMultiparts(tx *sql.Tx, changes []queue.MultipartChange) error {
	for _, ch := range changes {
		if ch.Record == nil {
			if _, err := tx.Exec(`DELETE FROM multiparts WHERE upload_id = ? AND idx = ?`, ch.UploadID, ch.Index); err != nil {
				return fmt.Errorf("clear multipart record: %w", err)
			}
			continue
		}
		m := ch.Record
		parts, err := encodeParts(m.Parts)
		if err != nil {
			return err
		}
		if _, err := tx.Exec(`INSERT OR REPLACE INTO multiparts
			(upload_id, idx, object_key, s3_upload_id, part_size, file_size, mod_time_ns, parts)
			SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM files WHERE upload_id = ? AND idx = ?)`,
			ch.UploadID, ch.Index, m.Key, m.UploadID, m.PartSize, m.FileSize, m.ModTimeNanos, parts,
			ch.UploadID, ch.Index); err != nil {
			return fmt.Errorf("save multipart record: %w", err)
		}
	}
	return nil
}

// Multiparts returns the multipart records of the files of an upload, by file
// index.
func (s *Store) Multiparts(uploadID string) (map[int]uploader.Multipart, error) {
	rows, err := s.db.Query(`SELECT idx, object_key, s3_upload_id, part_size, file_size, mod_time_ns, parts
		FROM multiparts WHERE upload_id = ?`, uploadID)
	if err != nil {
		return nil, fmt.Errorf("query multiparts: %w", err)
	}
	defer func() { _ = rows.Close() }()
	out := map[int]uploader.Multipart{}
	for rows.Next() {
		var (
			idx   int
			m     uploader.Multipart
			parts string
		)
		if err := rows.Scan(&idx, &m.Key, &m.UploadID, &m.PartSize, &m.FileSize, &m.ModTimeNanos, &parts); err != nil {
			return nil, fmt.Errorf("read multipart: %w", err)
		}
		if m.Parts, err = decodeParts(parts); err != nil {
			return nil, err
		}
		out[idx] = m
	}
	return out, rows.Err()
}
