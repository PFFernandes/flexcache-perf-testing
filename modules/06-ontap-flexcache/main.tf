# TODO (layer 4) - resources this module will create (NetApp/netapp-ontap provider):
#
#   random_password.peer_passphrase
#   data.netapp-ontap_cluster.origin / .cache          cluster names for SVM peering
#   netapp-ontap_cluster_peer.this                     cx_profile = cache, peer_cx_profile = origin
#        remote.ip_addresses         = var.origin_intercluster_ips
#        source_details.ip_addresses = var.cache_intercluster_ips
#        peer_applications           = ["snapmirror", "flexcache"]
#   netapp-ontap_svm_peer.this                         cache SVM <-> origin SVM, applications ["flexcache"]
#   netapp-ontap_flexcache.this                        on cache SVM, origins = [{ volume, svm }]
#
# Traffic for all of the above uses the intercluster endpoints (TCP 11104/11105),
# which route over the VPC peering created in stacks/01-landing-zone.
