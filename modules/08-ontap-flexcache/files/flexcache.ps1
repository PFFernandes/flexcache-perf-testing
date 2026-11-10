<#
FlexCache configuration through the ONTAP REST API - Windows version of flexcache.py.

Runs ON THE ORIGIN WINDOWS CLIENT when protocol = "smb" (sent there by
stacks/04-flexcache with SSM Run Command, document AWS-RunPowerShellScript).
The FSx for ONTAP Origin management IP is local; the Cache one is reached over
the VPC peering.

    flexcache.ps1 create <config-base64>
    flexcache.ps1 delete <config-base64>

create (idempotent - every step checks what already exists):
  1. cluster peer   Origin <-> Cache over the intercluster LIFs, one-time passphrase
  2. SVM peer       svm_cache <-> svm_origin, application "flexcache"
  3. FlexCache      vol_cache on svm_cache, origin = vol_origin on svm_origin
  4. SMB shares     "Origin" on svm_origin -> vol_origin, "Cache" on svm_cache -> vol_cache
delete: the same in reverse (shares, FlexCache, SVM peer, cluster peer).

The fsxadmin password is read here from Secrets Manager with the instance role
(AWS Tools for PowerShell, preinstalled on Windows AMIs), so it never appears in
the SSM command. Works on Windows PowerShell 5.1 and PowerShell 7.
#>
param(
    [Parameter(Mandatory = $true)][ValidateSet('create', 'delete')][string]$Action,
    [Parameter(Mandatory = $true)][string]$ConfigB64
)

$ErrorActionPreference = 'Stop'
$PeerTimeout = 600   # seconds to wait for the cluster / SVM peer to become available
$JobTimeout = 1800   # seconds to wait for an ONTAP job (FlexCache create/delete)

# Straight to stdout: never part of a function's return value.
function Write-Log([string]$Message) { [Console]::Out.WriteLine("[flexcache] $Message") }

$cfg = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ConfigB64)) | ConvertFrom-Json

# FSx for ONTAP uses a self-signed certificate.
if ($PSVersionTable.PSVersion.Major -lt 6) {
    if (-not ('FsxnTrustAll' -as [type])) {
        Add-Type -TypeDefinition @"
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class FsxnTrustAll : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
"@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object FsxnTrustAll
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $script:TlsParams = @{}
} else {
    $script:TlsParams = @{ SkipCertificateCheck = $true }
}

# --- minimal ONTAP REST client ------------------------------------------------------

function New-Ontap([string]$Label, [string]$Address, [string]$User, [string]$Password) {
    $token = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("${User}:${Password}"))
    return @{ Label = $Label; Address = $Address; Headers = @{ Authorization = "Basic $token"; Accept = 'application/json' } }
}

function Invoke-Ontap($Ontap, [string]$Method, [string]$Path, $Body = $null, [switch]$OkMissing) {
    $params = @{
        Method      = $Method
        Uri         = "https://$($Ontap.Address)/api$Path"
        Headers     = $Ontap.Headers
        ContentType = 'application/json'
        TimeoutSec  = 120
    } + $script:TlsParams
    if ($null -ne $Body) { $params.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress }

    for ($attempt = 0; $attempt -lt 5; $attempt++) {
        try {
            $resp = Invoke-RestMethod @params
            if ($null -eq $resp -or "$resp" -eq '') { return @{} }
            return $resp
        } catch {
            $http = $_.Exception.Response
            if ($null -ne $http) {
                $code = [int]$http.StatusCode
                if ($code -eq 404 -and $OkMissing) { return $null }
                throw "$($Ontap.Label): $Method $Path -> HTTP ${code}: $($_.ErrorDetails.Message)"
            }
            if ($attempt -eq 4) { throw "$($Ontap.Label): cannot reach $($Ontap.Address): $($_.Exception.Message)" }
            Write-Log "$($Ontap.Label): $($Ontap.Address) not reachable ($($_.Exception.Message)), retrying..."
            Start-Sleep -Seconds 10
        }
    }
}

function Get-Records($Ontap, [string]$Path) {
    $resp = Invoke-Ontap $Ontap 'GET' $Path
    if ($resp -and $resp.records) { return , @($resp.records) }
    return , @()
}

# POST/PATCH/DELETE may answer 202 with a job: wait for it to finish.
function Wait-OntapJob($Ontap, $Resp, [string]$What) {
    if (-not $Resp -or -not $Resp.job) { return }
    $deadline = (Get-Date).AddSeconds($JobTimeout)
    while ((Get-Date) -lt $deadline) {
        $job = Invoke-Ontap $Ontap 'GET' "/cluster/jobs/$($Resp.job.uuid)?fields=state,message,error"
        if ($job.state -eq 'success') { return }
        if ($job.state -eq 'failure') {
            throw "$($Ontap.Label): $What failed: $($job.message) $(ConvertTo-Json -InputObject $job.error -Compress)"
        }
        Start-Sleep -Seconds 5
    }
    throw "$($Ontap.Label): $What still running after ${JobTimeout}s"
}

function Wait-Until([scriptblock]$Check, [string]$What, [int]$Timeout = $PeerTimeout) {
    $deadline = (Get-Date).AddSeconds($Timeout)
    while ((Get-Date) -lt $deadline) {
        if (& $Check) { return }
        Start-Sleep -Seconds 10
    }
    throw "timed out waiting for $What"
}

function Read-FsxadminSecret([string]$Arn, [string]$Region) {
    Import-Module AWSPowerShell -ErrorAction SilentlyContinue
    for ($attempt = 0; $attempt -lt 12; $attempt++) {   # the endpoint may still be coming up
        try {
            return (Get-SECSecretValue -SecretId $Arn -Region $Region).SecretString | ConvertFrom-Json
        } catch {
            Write-Log "reading the fsxadmin secret failed ($($_.Exception.Message)), retrying..."
            Start-Sleep -Seconds 15
        }
    }
    throw 'cannot read the fsxadmin secret from Secrets Manager'
}

# --- cluster peer ------------------------------------------------------------------------

function Get-ClusterPeer($Side, [string]$RemoteName) {
    $recs = Get-Records $Side "/cluster/peers?name=$RemoteName&fields=name,status"
    if ($recs.Count -gt 0) { return $recs[0] }
    return $null
}

function New-ClusterPeer($O, $C, [string]$OName, [string]$CName) {
    $po = Get-ClusterPeer $O $CName
    $pc = Get-ClusterPeer $C $OName
    if ($po -and $pc) {
        Write-Log "cluster peer $OName <-> $CName already exists"
    } else {
        # Half a peer (e.g. from an interrupted run) can't be completed without its
        # passphrase, so remove it and create both sides fresh.
        foreach ($pair in @(@($O, $po), @($C, $pc))) {
            if ($pair[1]) {
                Write-Log "$($pair[0].Label): removing incomplete cluster peer $($pair[1].name)"
                Invoke-Ontap $pair[0] 'DELETE' "/cluster/peers/$($pair[1].uuid)" | Out-Null
            }
        }
        $chars = [char[]]'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'
        $bytes = New-Object byte[] 24
        [Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $passphrase = -join ($bytes | ForEach-Object { $chars[$_ % $chars.Length] })

        Write-Log "creating cluster peer on the Origin -> Cache intercluster $($cfg.cache.intercluster_ips -join ', ')"
        Invoke-Ontap $O 'POST' '/cluster/peers' @{
            remote         = @{ ip_addresses = @($cfg.cache.intercluster_ips) }
            authentication = @{ passphrase = $passphrase }
        } | Out-Null
        Write-Log "creating cluster peer on the Cache -> Origin intercluster $($cfg.origin.intercluster_ips -join ', ')"
        Invoke-Ontap $C 'POST' '/cluster/peers' @{
            remote         = @{ ip_addresses = @($cfg.origin.intercluster_ips) }
            authentication = @{ passphrase = $passphrase }
        } | Out-Null
    }

    Wait-Until {
        $a = Get-ClusterPeer $O $CName
        $b = Get-ClusterPeer $C $OName
        $sa = if ($a) { $a.status.state } else { $null }
        $sb = if ($b) { $b.status.state } else { $null }
        Write-Log "cluster peer state: origin=$sa cache=$sb"
        ($sa -eq 'available') -and ($sb -eq 'available')
    } 'the cluster peer to become available'
}

# --- SVM peer ----------------------------------------------------------------------------

function Get-SvmPeer($Side, [string]$Svm, [string]$Peer) {
    $recs = Get-Records $Side "/svm/peers?svm.name=$Svm&peer.svm.name=$Peer&fields=state,applications"
    if ($recs.Count -gt 0) { return $recs[0] }
    return $null
}

function New-SvmPeer($O, $C, [string]$OCluster) {
    $oSvm = $cfg.origin.svm_name
    $cSvm = $cfg.cache.svm_name

    if (-not (Get-SvmPeer $C $cSvm $oSvm)) {
        Write-Log "creating SVM peer $cSvm -> $oSvm (application flexcache)"
        Invoke-Ontap $C 'POST' '/svm/peers' @{
            svm          = @{ name = $cSvm }
            peer         = @{ svm = @{ name = $oSvm }; cluster = @{ name = $OCluster } }
            applications = @('flexcache')
        } | Out-Null
    } else {
        Write-Log "SVM peer $cSvm -> $oSvm already exists"
    }

    Wait-Until {
        $rc = Get-SvmPeer $C $cSvm $oSvm
        $ro = Get-SvmPeer $O $oSvm $cSvm
        if ($ro -and $ro.state -eq 'pending') {
            Write-Log "accepting SVM peer on the Origin ($oSvm)"
            Invoke-Ontap $O 'PATCH' "/svm/peers/$($ro.uuid)" @{ state = 'peered' } | Out-Null
        }
        $state = if ($rc) { $rc.state } else { $null }
        Write-Log "SVM peer state: $state"
        $state -eq 'peered'
    } 'the SVM peer to become peered'

    $rec = Get-SvmPeer $C $cSvm $oSvm
    $apps = @($rec.applications)
    if ($apps -notcontains 'flexcache') {
        Write-Log 'adding the flexcache application to the SVM peer'
        Invoke-Ontap $C 'PATCH' "/svm/peers/$($rec.uuid)" @{ applications = @(($apps + 'flexcache') | Sort-Object -Unique) } | Out-Null
    }
}

# --- FlexCache volume ----------------------------------------------------------------------

function Find-FlexCache($C) {
    $recs = Get-Records $C "/storage/flexcache/flexcaches?name=$($cfg.flexcache.name)&svm.name=$($cfg.cache.svm_name)"
    if ($recs.Count -gt 0) { return $recs[0] }
    return $null
}

function New-FlexCache($C) {
    $fc = $cfg.flexcache
    if (Find-FlexCache $C) {
        Write-Log "FlexCache $($fc.name) already exists"
        return
    }
    Write-Log ("creating FlexCache $($fc.name) ($($fc.size_gib) GiB) on $($cfg.cache.svm_name), " +
        "origin $($cfg.origin.volume_name) on $($cfg.origin.svm_name), path $($fc.junction_path)")
    $resp = Invoke-Ontap $C 'POST' '/storage/flexcache/flexcaches?return_timeout=120' @{
        name       = $fc.name
        svm        = @{ name = $cfg.cache.svm_name }
        origins    = @(@{ volume = @{ name = $cfg.origin.volume_name }; svm = @{ name = $cfg.origin.svm_name } })
        size       = [int64]$fc.size_gib * 1GB
        path       = $fc.junction_path
        aggregates = @($fc.aggregates | ForEach-Object { @{ name = $_ } })
    }
    Wait-OntapJob $C $resp "FlexCache $($fc.name) create"
    Write-Log "FlexCache $($fc.name) created and mounted at $($fc.junction_path)"
}

# --- SMB shares ------------------------------------------------------------------------------

function Get-Share($Side, [string]$Svm, [string]$Name) {
    return Get-Records $Side "/protocols/cifs/shares?svm.name=$Svm&name=$Name&fields=name,path,svm"
}

function New-Share($Side, [string]$Svm, [string]$Name, [string]$Path) {
    if ((Get-Share $Side $Svm $Name).Count -gt 0) {
        Write-Log "$($Side.Label): SMB share $Name already exists"
        return
    }
    Write-Log "$($Side.Label): creating SMB share $Name -> $Path on $Svm"
    Invoke-Ontap $Side 'POST' '/protocols/cifs/shares' @{ svm = @{ name = $Svm }; name = $Name; path = $Path } | Out-Null
}

function Remove-Share($Side, [string]$Svm, [string]$Name) {
    foreach ($rec in (Get-Share $Side $Svm $Name)) {
        Write-Log "$($Side.Label): deleting SMB share $Name"
        Invoke-Ontap $Side 'DELETE' "/protocols/cifs/shares/$($rec.svm.uuid)/$Name" -OkMissing | Out-Null
    }
}

# --- actions -------------------------------------------------------------------------------

function Connect-Clusters {
    $secret = Read-FsxadminSecret $cfg.secret_arn $cfg.secret_region
    $o = New-Ontap 'Origin' $cfg.origin.management_ip $secret.username $secret.password
    $c = New-Ontap 'Cache' $cfg.cache.management_ip $secret.username $secret.password
    $oName = (Invoke-Ontap $o 'GET' '/cluster?fields=name,version').name
    $cName = (Invoke-Ontap $c 'GET' '/cluster?fields=name,version').name
    Write-Log "Origin cluster $oName ($($cfg.origin.management_ip)), Cache cluster $cName ($($cfg.cache.management_ip))"
    return @($o, $c, $oName, $cName)
}

function Invoke-Create {
    $o, $c, $oName, $cName = Connect-Clusters
    New-ClusterPeer $o $c $oName $cName
    New-SvmPeer $o $c $oName
    New-FlexCache $c
    if ($cfg.shares) {
        New-Share $o $cfg.origin.svm_name $cfg.shares.origin.name $cfg.shares.origin.path
        New-Share $c $cfg.cache.svm_name $cfg.shares.cache.name $cfg.shares.cache.path
    }
    Write-Log 'done: cluster peer, SVM peer, FlexCache and SMB shares are in place'
}

function Invoke-Delete {
    $o, $c, $oName, $cName = Connect-Clusters
    if ($cfg.shares) {
        Remove-Share $c $cfg.cache.svm_name $cfg.shares.cache.name
        Remove-Share $o $cfg.origin.svm_name $cfg.shares.origin.name
    }

    $fc = Find-FlexCache $c
    if ($fc) {
        Write-Log "unmounting and taking FlexCache $($cfg.flexcache.name) offline"
        Wait-OntapJob $c (Invoke-Ontap $c 'PATCH' "/storage/volumes/$($fc.uuid)" @{ nas = @{ path = '' } }) 'unmount'
        Wait-OntapJob $c (Invoke-Ontap $c 'PATCH' "/storage/volumes/$($fc.uuid)" @{ state = 'offline' }) 'offline'
        Write-Log "deleting FlexCache $($cfg.flexcache.name)"
        Wait-OntapJob $c (Invoke-Ontap $c 'DELETE' "/storage/flexcache/flexcaches/$($fc.uuid)") 'FlexCache delete'
    } else {
        Write-Log 'no FlexCache to delete'
    }

    $oSvm = $cfg.origin.svm_name
    $cSvm = $cfg.cache.svm_name
    foreach ($t in @(@($c, $cSvm, $oSvm), @($o, $oSvm, $cSvm))) {
        foreach ($rec in (Get-Records $t[0] "/svm/peers?svm.name=$($t[1])&peer.svm.name=$($t[2])")) {
            Write-Log "$($t[0].Label): deleting SVM peer $($t[1]) -> $($t[2])"
            Wait-OntapJob $t[0] (Invoke-Ontap $t[0] 'DELETE' "/svm/peers/$($rec.uuid)" -OkMissing) 'SVM peer delete'
        }
    }

    foreach ($t in @(@($c, $oName), @($o, $cName))) {
        foreach ($rec in (Get-Records $t[0] "/cluster/peers?name=$($t[1])")) {
            Write-Log "$($t[0].Label): deleting cluster peer $($t[1])"
            Invoke-Ontap $t[0] 'DELETE' "/cluster/peers/$($rec.uuid)" -OkMissing | Out-Null
        }
    }
    Write-Log 'done: SMB shares, FlexCache, SVM peer and cluster peer removed'
}

try {
    if ($Action -eq 'create') { Invoke-Create } else { Invoke-Delete }
} catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
exit 0
