<#
.SYNOPSIS
  Stops every Portfolio 5 test instance and deletes the .cluster folder.
  Only touches portfolio-5-distributed-cloud\.cluster. Your main PostgreSQL service is not affected.
#>
param([switch]$Force)
. "$PSScriptRoot\common.ps1"
if (-not $Force) {
    $answer = Read-Host "Delete all test instances under $Cluster ? (y/N)"
    if ($answer -ne 'y') { Write-Host 'Cancelled.'; return }
}
foreach ($n in 'replica1', 'primary', 'router', 'shard1', 'shard2') { Stop-Node -Name $n }
Start-Sleep -Seconds 2
Remove-Item -Recurse -Force $Cluster -ErrorAction SilentlyContinue
Write-Host 'Cleaned up.'
