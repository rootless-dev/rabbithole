package queue

// recordOf is the stored form of an upload.
func recordOf(u *upload) UploadRecord {
	return UploadRecord{Snapshot: u.snap, Bucket: u.bucket, Region: u.region, Prefix: u.prefix, Parallel: u.parallel}
}

func itemRecords(items []item) []ItemRecord {
	out := make([]ItemRecord, len(items))
	for i, it := range items {
		out[i] = ItemRecord{Index: i, Path: it.path, IsDir: it.isDir, DestName: it.destName, Resolved: it.resolved}
	}
	return out
}

func fileRecord(f *fileState) FileRecord {
	return FileRecord{Snapshot: f.snap, Item: f.plan.item, Inner: f.plan.inner, Unreadable: f.plan.unreadable}
}

func fileRecords(files []*fileState) []FileRecord {
	out := make([]FileRecord, len(files))
	for i, f := range files {
		out[i] = fileRecord(f)
	}
	return out
}

func filesSnapshots(files []*fileState) []FileSnapshot {
	out := make([]FileSnapshot, 0, len(files))
	for _, f := range files {
		out = append(out, f.snap)
	}
	return out
}

func recordSnapshots(recs []FileRecord) []FileSnapshot {
	out := make([]FileSnapshot, 0, len(recs))
	for _, r := range recs {
		out = append(out, r.Snapshot)
	}
	return out
}
