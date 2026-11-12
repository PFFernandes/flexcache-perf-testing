# 12-bench-results-volume

The test bench **results volume**: an FSx for ONTAP volume, `vol_bench` by default, on the origin
file system (or the cache one, `results_volume.side` in stack 05). Both clients mount it over NFS
at `/mnt/fsxn/vol_bench` (`modules/11-bench-telemetry`), and every result is written there:
OpenTelemetry telemetry, dataset records, logs, the lab description. Nothing goes to S3.
Called by `stacks/05-bench` when `telemetry = true`.

| Resource | Setting |
|---|---|
| `aws_fsx_ontap_volume.this` | FlexVol, junction `/vol_bench`, 100 GiB, UNIX security style, storage efficiency on, tiering `NONE` (all on SSD), snapshot policy `default` |

## Keeping the results after the lab

**`skip_final_backup = false`**: when the volume is deleted (destroying `stacks/05-bench`), FSx
takes a **final backup** of it first, tagged `Purpose = bench-results` and `Lab = <lab>`. The backup
is independent of the file system, so it outlives destroying `02-fsxn` too, and a later lab can be
given the old results back by restoring it as a volume.

- Destroy `05-bench` **before** `02-fsxn`: the volume has to be deleted through this module for the
  final backup to happen (and an SVM with volumes in it can't be deleted anyway).
- List the backups of a volume (the exact command is `final_backups` in `./tf.sh 05-bench output`):

  ```bash
  aws fsx describe-backups --region <region> --filters Name=volume-id,Values=<volume-id>
  ```

  After the volume is gone, find them by tag:

  ```bash
  aws fsx describe-backups --region <region> --query "Backups[?Tags[?Key=='Purpose' && Value=='bench-results']].[BackupId,CreationTime,Volume.Name]" --output table
  ```

- To discard the results instead, set `skip_final_backup = true`, **apply**, then destroy (FSx reads
  the setting from the volume, so it must be applied first).
- FSx backups are billed per GB-month of backup storage; delete old ones with
  `aws fsx delete-backup --backup-id <id>`.

Restoring a backup into a new lab is not automated yet.

| Variable | Default | |
|---|---|---|
| `name`, `lab` | – | Name tag; lab tag on the volume and its final backup |
| `file_system_id` | – | origin (default) or cache file system |
| `volume_name` / `junction_path` | `vol_bench` / `/vol_bench` | |
| `size_gib` | `100` | telemetry is a few hundred MB per client per day before compression |
| `snapshot_policy` | `default` | hourly, daily and weekly ONTAP snapshots |
| `skip_final_backup` | `false` | see above |

Outputs: `volume_id`, `volume_name`, `junction_path`, `svm_name`.
