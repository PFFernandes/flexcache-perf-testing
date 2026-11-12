# Test bench results volume: an FSx for ONTAP volume (default vol_bench) on the origin or the
# cache file system. Both clients mount it over NFS; the OpenTelemetry Collector, bench-probe
# and bench-dataset write all results there (nothing goes to S3).
#
# When the volume is deleted (destroying stacks/05-bench), FSx takes a FINAL BACKUP of it. The
# backup outlives the lab (also destroying 02-fsxn), so the results of a lab can be restored
# into a new one later. Backups are listed with:
#   aws fsx describe-backups --filters Name=volume-id,Values=<volume-id>
#
# Resources:
#   aws_fsx_ontap_volume.this   FlexVol, UNIX security style, storage efficiency on
#
# Tags: Name = <var.name>, plus the Creator tag from the provider default_tags; the final
# backup gets the same tags plus Purpose = bench-results and Lab = <var.lab>.

data "aws_fsx_ontap_storage_virtual_machine" "svm" {
  filter {
    name   = "file-system-id"
    values = [var.file_system_id]
  }
}

resource "aws_fsx_ontap_volume" "this" {
  name                       = var.volume_name
  storage_virtual_machine_id = data.aws_fsx_ontap_storage_virtual_machine.svm.id
  volume_style               = "FLEXVOL"
  junction_path              = var.junction_path
  size_in_megabytes          = var.size_gib * 1024
  security_style             = "UNIX"
  storage_efficiency_enabled = true # telemetry is JSON text: compresses well
  snapshot_policy            = var.snapshot_policy
  ontap_volume_type          = "RW"
  copy_tags_to_backups       = true

  tiering_policy {
    name = "NONE" # results stay on SSD: small, and read back by the report
  }

  # The point of this volume: keep the results when the lab goes. FSx backs it up when
  # it's deleted. Set skip_final_backup = true (and apply) only to throw results away.
  skip_final_backup = var.skip_final_backup
  final_backup_tags = {
    Name    = "${var.name}-final"
    Purpose = "bench-results"
    Lab     = var.lab
  }

  tags = {
    Name    = var.name
    Purpose = "bench-results"
    Lab     = var.lab
  }
}
