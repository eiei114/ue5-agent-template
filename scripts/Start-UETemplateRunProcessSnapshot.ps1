# Captures the process snapshot a run needs to prove which processes it owns.
#
# docs/01-start.md defines the run-owned scope and requires the lease to carry the attribution
# evidence. This script only reads the process table (Win32_Process) and writes JSON; it never
# starts, stops or attaches to a UE process.
#
#   scripts\Start-UETemplateRunProcessSnapshot.ps1 `
#     -RunId <runid> -WriterProcessId <writer pid> `
#     -SnapshotPath '<project>\Out\run_<runid>\evidence\process-snapshot.json'
#
# Optionally point -LeasePath at an existing LEASE.json to record the snapshot reference in the
# lease. The lease's other fields are compared before and after and the write is refused if any of
# them changed; exclusive lease creation and contention stay with DOT-3042 (UE-LEASE-001).

[CmdletBinding()]
param(
	[Parameter(Mandatory = $true)]
	[string]$RunId,

	[int]$WriterProcessId = 0,

	[string]$SnapshotPath = '',

	[string]$LeasePath = '',

	[string]$ProjectRealPath = '',

	[string]$IssueId = '',

	[string]$HostName = '',

	[string[]]$PreserveProcessNames = @('chrome'),

	[switch]$AllowMissingWriterBoundary
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'UETemplateProcessOwnership.ps1')

if ([string]::IsNullOrWhiteSpace($RunId)) { throw 'RunId is required.' }
if ($WriterProcessId -le 0) { $WriterProcessId = [int]$PID }
if ([string]::IsNullOrWhiteSpace($HostName)) { $HostName = [System.Net.Dns]::GetHostName() }

$liveTable = Get-UETemplateLiveProcessTable
$index = Get-UETemplateProcessIndex -Table $liveTable
$writer = $index.byId[$WriterProcessId]
if ($null -eq $writer) {
	throw ("Writer process {0} is not in the captured process table. A snapshot without its writer cannot attribute anything." -f $WriterProcessId)
}

$ancestors = @(Get-UETemplateProcessAncestors -Index $index -ProcessId $WriterProcessId)
if ($ancestors.Count -eq 0 -and -not $AllowMissingWriterBoundary) {
	throw 'The writer has no recorded ancestor, so the boundary between the run and its supervisor is unknown. Pass -AllowMissingWriterBoundary only when the run really is the top-level process.'
}

$preserveNames = @($PreserveProcessNames | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
$excludedProcessIds = @($liveTable | Where-Object { $preserveNames -contains ([string]$_.name).ToLowerInvariant() } | ForEach-Object { [int]$_.process_id })

$snapshot = [pscustomobject]@{
	schema_version              = 1
	run_id                      = $RunId
	issue_id                    = $IssueId
	host                        = $HostName
	project_realpath            = $ProjectRealPath
	captured_at_utc             = [datetime]::UtcNow.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
	writer                      = [pscustomobject]@{
		process_id         = [int]$writer.process_id
		creation_utc_ticks = [long]$writer.creation_utc_ticks
		executable_path    = [string]$writer.executable_path
		name               = [string]$writer.name
	}
	roots                       = @([int]$writer.process_id)
	boundary_ancestor_process_ids = @($ancestors | ForEach-Object { [int]$_.process_id })
	excluded_process_ids        = @($excludedProcessIds)
	preserve_process_names      = @($preserveNames)
	process_count               = @($liveTable).Count
	processes                   = @($liveTable | ForEach-Object {
		[pscustomobject]@{
			process_id         = [int]$_.process_id
			parent_process_id  = [int]$_.parent_process_id
			creation_utc_ticks = [long]$_.creation_utc_ticks
			executable_path    = [string]$_.executable_path
			name               = [string]$_.name
		}
	})
}

if ([string]::IsNullOrWhiteSpace($SnapshotPath)) {
	throw 'SnapshotPath is required. Record it under <project>\Out\run_<runid>\evidence\ so the run keeps its evidence with its output.'
}
$SnapshotPath = [System.IO.Path]::GetFullPath($SnapshotPath)
if (Test-Path -LiteralPath $SnapshotPath) {
	throw ("Snapshot already exists; a run captures its process table once: {0}" -f $SnapshotPath)
}
Write-UETemplateJsonFile -Path $SnapshotPath -Value $snapshot -Exclusive

$snapshotSha = (Get-UETemplateFileSha256 -Path $SnapshotPath)
$ownership = Resolve-UETemplateRunOwnership -Snapshots @($snapshot) -LiveTable $liveTable -PreserveProcessNames $preserveNames
$snapshotReference = [pscustomobject]@{
	schema_version            = 1
	path                      = $SnapshotPath
	sha256                    = $snapshotSha
	captured_at_utc           = $snapshot.captured_at_utc
	writer_process_id         = [int]$writer.process_id
	writer_creation_utc_ticks = [long]$writer.creation_utc_ticks
	root_process_ids          = @($snapshot.roots)
	boundary_ancestor_process_ids = @($snapshot.boundary_ancestor_process_ids)
	process_count             = [int]$snapshot.process_count
}

if (-not [string]::IsNullOrWhiteSpace($LeasePath)) {
	$LeasePath = [System.IO.Path]::GetFullPath($LeasePath)
	$lease = Read-UETemplateJsonFile -Path $LeasePath -Description 'lease'
	# Record the snapshot reference without touching any existing lease field. Exclusive creation and
	# contention detection stay with DOT-3042 (UE-LEASE-001).
	$originalFields = @{}
	foreach ($property in $lease.PSObject.Properties) {
		$originalFields[$property.Name] = (ConvertTo-Json -InputObject @{ value = $property.Value } -Depth 12 -Compress)
	}
	$lease | Add-Member -NotePropertyName 'process_snapshot' -NotePropertyValue $snapshotReference -Force
	Write-UETemplateJsonFile -Path $LeasePath -Value $lease

	$written = Read-UETemplateJsonFile -Path $LeasePath -Description 'lease'
	$drift = New-Object System.Collections.Generic.List[string]
	foreach ($name in $originalFields.Keys) {
		$property = $written.PSObject.Properties[$name]
		if ($null -eq $property) {
			$drift.Add(("lease field disappeared: {0}" -f $name))
			continue
		}
		$serialized = ConvertTo-Json -InputObject @{ value = $property.Value } -Depth 12 -Compress
		if ($serialized -cne $originalFields[$name]) { $drift.Add(("lease field changed: {0}" -f $name)) }
	}
	if ($null -eq $written.PSObject.Properties['process_snapshot']) {
		$drift.Add('lease field missing: process_snapshot')
	}
	if ($drift.Count -gt 0) {
		throw ('Recording the snapshot reference changed the lease: ' + ($drift -join '; '))
	}
	Write-Output ("LEASE: process_snapshot recorded in {0}" -f $LeasePath)
}

Write-Output ("SNAPSHOT: {0}" -f $SnapshotPath)
Write-Output ("SHA256: {0}" -f $snapshotSha)
Write-Output ("WRITER: pid={0} creation_utc_ticks={1} name={2}" -f $writer.process_id, $writer.creation_utc_ticks, $writer.name)
Write-Output ("BOUNDARY: {0}" -f (($snapshot.boundary_ancestor_process_ids | ForEach-Object { [string]$_ }) -join ','))
Write-Output ("PROCESSES: {0}" -f $snapshot.process_count)
Write-Output ("OWNED: {0} EXCLUDED: {1} GAPS: {2}" -f @($ownership.owned).Count, @($ownership.excluded).Count, @($ownership.gaps).Count)
Write-Output 'UE: not started (snapshot only reads the process table)'
exit 0
