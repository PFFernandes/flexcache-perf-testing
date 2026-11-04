# scripts/origin – dataset generation (runs on the origin EC2 client)

Planned:

- `mount-origin.sh` – mount the origin volume (`<svm_nfs_ip>:/vol_origin` → `/mnt/fsxn/origin`)
  with configurable NFS options (`vers`, `nconnect`, `rsize/wsize`).
- `generate-dataset.sh` – create reproducible test files on the origin volume, e.g. profiles:
  - `small` – many small files (metadata-heavy, e.g. 100k × 64 KiB)
  - `large` – few large files (throughput, e.g. 50 × 10 GiB)
  - `mixed` – realistic mix
  Writes a manifest (file list + sizes + checksums) so the cache side reads exactly the same set.

Values like the SVM NFS IP come from `../../tf.sh 02-fsxn output`.
