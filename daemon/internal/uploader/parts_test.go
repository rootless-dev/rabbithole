package uploader

import "testing"

func TestUseMultipartBoundary(t *testing.T) {
	tests := []struct {
		name string
		size int64
		want bool
	}{
		{"empty file", 0, false},
		{"one byte below threshold", 16*MiB - 1, false},
		{"at threshold", 16 * MiB, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := UseMultipart(tt.size); got != tt.want {
				t.Errorf("UseMultipart(%d) = %v, want %v", tt.size, got, tt.want)
			}
		})
	}
}

func TestPartSize(t *testing.T) {
	tests := []struct {
		name string
		size int64
		want int64
	}{
		{"empty file", 0, 8 * MiB},
		{"multipart threshold", 16 * MiB, 8 * MiB},
		{"largest size at 8 MiB parts", 80000 * MiB, 8 * MiB},
		{"one byte above forces 9 MiB", 80000*MiB + 1, 9 * MiB},
		{"160000 MiB", 160000 * MiB, 16 * MiB},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := PartSize(tt.size); got != tt.want {
				t.Errorf("PartSize(%d) = %d, want %d", tt.size, got, tt.want)
			}
		})
	}
}
