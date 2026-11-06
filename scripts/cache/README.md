# scripts/cache – read performance measurement (runs on the cache EC2 client, /mnt/fsxn/vol_cache)

Planned:

- `mount-cache.sh` – mount the FlexCache volume (`<cache_svm_nfs_ip>:/vol_cache` → `/mnt/fsxn/cache`)
  and, for comparison, the origin volume directly over the peering (`/mnt/fsxn/origin-remote`).
- `read-benchmark.sh` – fio-based read tests, each run:
  1. **cold read** – first read through the cache (data fetched from origin over the WAN/peering)
  2. **warm read** – same files again (served from the cache)
  3. **direct-to-origin** baseline – same files read across the peering without FlexCache
  Client page cache is dropped between runs (`echo 3 > /proc/sys/vm/drop_caches`).
- Results written as CSV/JSON to `results/<timestamp>/` (git-ignored) with test metadata
  (regions, FSxN throughput, cache size, NFS options, file profile).
