package uploader

const (
	// MiB is one mebibyte in bytes.
	MiB = 1 << 20

	multipartThreshold = 16 * MiB
	minPartSize        = 8 * MiB
	maxParts           = 10000
)

// UseMultipart reports whether a file of the given size is uploaded in parts.
func UseMultipart(size int64) bool {
	return size >= multipartThreshold
}

// PartSize returns the multipart part size for a file of the given size: 8 MiB
// unless that would need more than 10,000 parts, in which case it is the
// smallest whole number of MiB that fits the file in 10,000 parts.
func PartSize(size int64) int64 {
	perPart := (size + maxParts - 1) / maxParts
	rounded := (perPart + MiB - 1) / MiB * MiB
	return max(rounded, minPartSize)
}
