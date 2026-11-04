terraform {
  required_version = ">= 1.10"

  required_providers {
    netapp-ontap = {
      source  = "NetApp/netapp-ontap"
      version = ">= 2.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6"
    }
  }
}
