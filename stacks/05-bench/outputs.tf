output "bench" {
  description = "null until the bench is deployed."
  value = length(module.bench) == 0 ? null : {
    bench_home    = module.bench[0].bench_home
    bundle_sha256 = module.bench[0].bundle_sha256
    files         = module.bench[0].file_count
    clients = {
      for side, id in module.bench[0].deployed_to : side => {
        instance_id = id
        login       = "aws ssm start-session --target ${id} --region ${local.clients[side].region}"
        first_test = (side == "origin"
          ? "bench-dataset create --target /mnt/fsxn/vol_origin --spec smoke"
        : "bench-dataset plan --spec smoke")
      }
    }
  }
}
