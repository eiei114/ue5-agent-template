# Run-owned process attribution for the UE production template.
#
# A run owns a process tree, not a process name. AGENTS.md forbids name-targeted kills
# (Stop-Process -Name, taskkill /IM, Get-Process <name> | Stop-Process), and the lease records a
# single writer PID, so attribution must come from a snapshot taken while the run was alive:
#
#   process identity = (process_id, creation_utc_ticks)
#
# creation_utc_ticks is the process creation time as UTC file time (100 ns ticks) derived from
# Win32_Process.CreationDate. ToFileTimeUtc() keeps the value independent of the machine's time zone
# and stable across Windows PowerShell 5.1 and PowerShell 7, so a snapshot compares exactly with a
# later enumeration.
#
# Attribution is computed from the snapshot(s) only. A live process that no snapshot recorded is
# never a stop target: it becomes an attribution gap, which keeps the verdict at `unknown`.
#
# Everything here is read-only. Start-UETemplateRunProcessSnapshot.ps1 captures a snapshot,
# Stop-UETemplateRunProcesses.ps1 stops by identity, and Get-UETemplateLeaseVerdict.ps1 reports
# free/held/unknown. All three dot-source this file.

function ConvertTo-UETemplateUtcTicks {
	# CreationDate arrives as a DateTime in the host's zone; file time is the stable wire form.
	param($CreationDate)

	if ($null -eq $CreationDate) { return [long]0 }
	try {
		if ($CreationDate -is [datetime]) { return [long]($CreationDate.ToFileTimeUtc()) }
		if ($CreationDate -is [long] -or $CreationDate -is [int]) { return [long]$CreationDate }
		return [long]0
	} catch {
		return [long]0
	}
}

function New-UETemplateProcessRecord {
	param([Parameter(Mandatory)]$Source)

	[pscustomobject]@{
		process_id         = [int]$Source.ProcessId
		parent_process_id  = [int]$Source.ParentProcessId
		creation_utc_ticks = ConvertTo-UETemplateUtcTicks -CreationDate $Source.CreationDate
		executable_path    = [string]$Source.ExecutablePath
		name               = [string]$Source.Name
	}
}

function Get-UETemplateLiveProcessTable {
	# One enumeration, so parents and children come from the same instant.
	$records = New-Object 'System.Collections.Generic.List[psobject]'
	foreach ($source in @(Get-CimInstance -ClassName Win32_Process)) {
		$records.Add((New-UETemplateProcessRecord -Source $source))
	}
	$records.ToArray()
}

function ConvertTo-UETemplateProcessTable {
	param([AllowNull()]$Records)

	$table = New-Object 'System.Collections.Generic.List[psobject]'
	foreach ($record in @($Records)) {
		if ($null -eq $record) { continue }
		if ($null -eq $record.process_id) { continue }
		$table.Add([pscustomobject]@{
			process_id         = [int]$record.process_id
			parent_process_id  = [int]$record.parent_process_id
			creation_utc_ticks = [long]$record.creation_utc_ticks
			executable_path    = [string]$record.executable_path
			name               = [string]$record.name
		})
	}
	$table.ToArray()
}

function Get-UETemplateProcessIndex {
	param([AllowNull()]$Table)

	$byId = @{}
	$children = @{}
	foreach ($record in @($Table)) {
		$id = [int]$record.process_id
		if (-not $byId.ContainsKey($id)) { $byId[$id] = $record }
	}
	foreach ($record in @($Table)) {
		$parentId = [int]$record.parent_process_id
		if ($parentId -le 0 -or $parentId -eq [int]$record.process_id) { continue }
		if (-not $children.ContainsKey($parentId)) { $children[$parentId] = New-Object 'System.Collections.Generic.List[psobject]' }
		$children[$parentId].Add($record)
	}
	@{ byId = $byId; children = $children }
}

function Test-UETemplateParentLink {
	# A recorded parent link is trusted only when the parent predates the child. A parent created
	# after its supposed child comes from a reused PID and must not glue a stranger into the tree.
	param($ChildRecord, $ParentRecord)

	if ($null -eq $ChildRecord -or $null -eq $ParentRecord) { return $false }
	$childTicks = [long]$ChildRecord.creation_utc_ticks
	$parentTicks = [long]$ParentRecord.creation_utc_ticks
	if ($childTicks -le 0 -or $parentTicks -le 0) { return $true }
	($parentTicks -lt $childTicks)
}

function Get-UETemplateProcessAncestors {
	# Walks captured parent links upward (cycle-safe, bounded). Used at capture time to record which
	# ancestors are a boundary the run must never stop.
	param([Parameter(Mandatory)]$Index, [int]$ProcessId, [int]$MaxDepth = 64)

	$chain = New-Object 'System.Collections.Generic.List[psobject]'
	$seen = @{}
	$current = $Index.byId[$ProcessId]
	while ($null -ne $current -and $chain.Count -lt $MaxDepth) {
		$id = [int]$current.process_id
		if ($seen.ContainsKey($id)) { break }
		$seen[$id] = $true
		$parentId = [int]$current.parent_process_id
		if ($parentId -le 0 -or $parentId -eq $id) { break }
		$parent = $Index.byId[$parentId]
		if ($null -eq $parent) { break }
		if (-not (Test-UETemplateParentLink -ChildRecord $current -ParentRecord $parent)) { break }
		$chain.Add($parent)
		$current = $parent
	}
	$chain.ToArray()
}

function Get-UETemplateProcessDepth {
	param([Parameter(Mandatory)]$Index, [int]$ProcessId, [int]$MaxDepth = 64)

	$depth = 0
	$current = $Index.byId[$ProcessId]
	$seen = @{}
	while ($null -ne $current -and $depth -lt $MaxDepth) {
		$id = [int]$current.process_id
		if ($seen.ContainsKey($id)) { break }
		$seen[$id] = $true
		$parentId = [int]$current.parent_process_id
		if ($parentId -le 0 -or $parentId -eq $id) { break }
		$parent = $Index.byId[$parentId]
		if ($null -eq $parent) { break }
		if (-not (Test-UETemplateParentLink -ChildRecord $current -ParentRecord $parent)) { break }
		$depth++
		$current = $parent
	}
	$depth
}

function Get-UETemplateProcessDepths {
	# Distance from the run roots (root = 0), which is what "deepest first" must mean. The absolute
	# depth in the machine-wide process tree is unrelated to how deep a run's own tree is.
	param([Parameter(Mandatory)]$Index, [int[]]$RootProcessIds, [int]$MaxDepth = 64)

	# The comma operator binds tighter than '+', so the depth must be parenthesised inside @(...);
	# otherwise @($child, $depth + 1) becomes a three element array with a stale depth.
	$depths = @{}
	$queue = New-Object 'System.Collections.Generic.Queue[object]'
	foreach ($rootId in @($RootProcessIds)) {
		$record = $Index.byId[[int]$rootId]
		if ($null -eq $record) { continue }
		if ($depths.ContainsKey([int]$record.process_id)) { continue }
		$depths[[int]$record.process_id] = 0
		$queue.Enqueue(@($record, 0))
	}
	while ($queue.Count -gt 0) {
		$item = $queue.Dequeue()
		$record = $item[0]
		$depth = [int]$item[1]
		if ($depth -ge $MaxDepth) { continue }
		$children = $Index.children[[int]$record.process_id]
		if ($null -eq $children) { continue }
		foreach ($child in $children) {
			$childId = [int]$child.process_id
			if ($depths.ContainsKey($childId)) { continue }
			if (-not (Test-UETemplateParentLink -ChildRecord $child -ParentRecord $record)) { continue }
			$depths[$childId] = $depth + 1
			$queue.Enqueue(@($child, ($depth + 1)))
		}
	}
	$depths
}

function Get-UETemplateProcessDescendants {
	# Breadth-first from the roots over the snapshot tree.
	param([Parameter(Mandatory)]$Index, [int[]]$RootProcessIds, [int]$MaxDepth = 64)

	$found = New-Object 'System.Collections.Generic.List[psobject]'
	$seen = @{}
	$queue = New-Object 'System.Collections.Generic.Queue[object]'
	foreach ($rootId in @($RootProcessIds)) {
		$record = $Index.byId[[int]$rootId]
		if ($null -eq $record) { continue }
		if ($seen.ContainsKey([int]$record.process_id)) { continue }
		$seen[[int]$record.process_id] = $true
		$queue.Enqueue(@($record, 0))
	}
	while ($queue.Count -gt 0) {
		$item = $queue.Dequeue()
		$record = $item[0]
		$depth = [int]$item[1]
		$found.Add($record)
		if ($depth -ge $MaxDepth) { continue }
		$children = $Index.children[[int]$record.process_id]
		if ($null -eq $children) { continue }
		foreach ($child in $children) {
			$childId = [int]$child.process_id
			if ($seen.ContainsKey($childId)) { continue }
			if (-not (Test-UETemplateParentLink -ChildRecord $child -ParentRecord $record)) { continue }
			$seen[$childId] = $true
			$queue.Enqueue(@($child, ($depth + 1)))
		}
	}
	$found.ToArray()
}

function Get-UETemplateSnapshotTree {
	# Unions one or more snapshots of the same run into a single tree. Several snapshots are allowed
	# because a run keeps launching processes: a workspace/maintained snapshot per capture point, all
	# with the same run_id. A PID recorded twice with different creation times is a reused PID and is
	# reported as a conflict instead of being merged.
	param([AllowNull()]$Snapshots)

	$records = @{}
	$conflicts = New-Object 'System.Collections.Generic.List[psobject]'
	$roots = New-Object 'System.Collections.Generic.List[int]'
	$boundary = New-Object 'System.Collections.Generic.List[int]'
	$excludedIds = New-Object 'System.Collections.Generic.List[int]'
	$writerRecord = $null
	$runIds = New-Object 'System.Collections.Generic.List[string]'

	foreach ($snapshot in @($Snapshots)) {
		if ($null -eq $snapshot) { continue }
		if ($null -ne $snapshot.run_id -and -not [string]::IsNullOrWhiteSpace([string]$snapshot.run_id)) {
			$runIds.Add([string]$snapshot.run_id)
		}
		if ($null -ne $snapshot.writer -and $null -eq $writerRecord) {
			$writerRecord = [pscustomobject]@{
				process_id         = [int]$snapshot.writer.process_id
				creation_utc_ticks = [long]$snapshot.writer.creation_utc_ticks
				executable_path    = [string]$snapshot.writer.executable_path
				name               = [string]$snapshot.writer.name
			}
		}
		foreach ($rootId in @($snapshot.roots)) {
			if ($null -eq $rootId) { continue }
			$id = [int]$rootId
			if ($roots -notcontains $id) { $roots.Add($id) }
		}
		foreach ($ancestorId in @($snapshot.boundary_ancestor_process_ids)) {
			if ($null -eq $ancestorId) { continue }
			$id = [int]$ancestorId
			if ($boundary -notcontains $id) { $boundary.Add($id) }
		}
		foreach ($excludedId in @($snapshot.excluded_process_ids)) {
			if ($null -eq $excludedId) { continue }
			$id = [int]$excludedId
			if ($excludedIds -notcontains $id) { $excludedIds.Add($id) }
		}
		foreach ($record in @(ConvertTo-UETemplateProcessTable -Records $snapshot.processes)) {
			$id = [int]$record.process_id
			if ($records.ContainsKey($id)) {
				$knownTicks = [long]$records[$id].creation_utc_ticks
				$newTicks = [long]$record.creation_utc_ticks
				if ($knownTicks -ne $newTicks -and $knownTicks -gt 0 -and $newTicks -gt 0) {
					$conflicts.Add([pscustomobject]@{ process_id = $id; creation_utc_ticks = $knownTicks; other_creation_utc_ticks = $newTicks; name = [string]$record.name })
				}
				continue
			}
			$records[$id] = $record
		}
	}

	$table = New-Object 'System.Collections.Generic.List[psobject]'
	foreach ($record in $records.Values) { $table.Add($record) }
	$writerTicks = [long]0
	if ($null -ne $writerRecord) { $writerTicks = [long]$writerRecord.creation_utc_ticks }
	if ($roots.Count -eq 0 -and $null -ne $writerRecord) { $roots.Add([int]$writerRecord.process_id) }

	[pscustomobject]@{
		records          = $table.ToArray()
		index            = Get-UETemplateProcessIndex -Table $table.ToArray()
		roots            = $roots.ToArray()
		boundary         = $boundary.ToArray()
		excluded_process_ids = $excludedIds.ToArray()
		conflicts        = $conflicts.ToArray()
		writer           = $writerRecord
		writer_creation_utc_ticks = $writerTicks
		run_ids          = $runIds.ToArray()
	}
}

function Resolve-UETemplateRunOwnership {
	# Classifies the processes a run owns, using the snapshot(s) as the evidence:
	#   owned    - reachable from the snapshot roots through trusted parent links, identity known
	#   excluded - owned by contract but deliberately not stopped (boundary ancestor, shared Chrome,
	#              another run's process, a PID that now belongs to someone else)
	#   gaps     - looks run-owned but the link/identity cannot be established; never stopped
	#
	# With no snapshot the function reports `snapshotMissing`: a single writer PID cannot attribute
	# descendants, and the caller must answer unknown, never free.
	param(
		[AllowNull()]$Snapshots,
		[AllowNull()]$LiveTable,
		[string[]]$PreserveProcessNames = @('chrome'),
		[AllowNull()]$OtherSnapshots = @(),
		[int[]]$AdditionalExcludeProcessIds = @()
	)

	$preserveNames = @($PreserveProcessNames | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
	$additionalExclude = @($AdditionalExcludeProcessIds | ForEach-Object { [int]$_ })

	$snapshotList = @($Snapshots | Where-Object { $null -ne $_ })
	if ($snapshotList.Count -eq 0) {
		return [pscustomobject]@{
			ok              = $false
			snapshotMissing = $true
			roots           = @()
			owned           = @()
			excluded        = @()
			gaps            = @([pscustomobject]@{ process_id = 0; name = ''; reason = 'snapshot-missing'; detail = 'no process snapshot is recorded for this run' })
			conflicts       = @()
			writer          = $null
		}
	}

	$tree = Get-UETemplateSnapshotTree -Snapshots $snapshotList
	$liveIndex = Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $LiveTable)

	# Another run's own tree is excluded even when this run spawned a helper next to it.
	$otherRunIds = @{}
	foreach ($other in @($OtherSnapshots)) {
		if ($null -eq $other) { continue }
		$otherTree = Get-UETemplateSnapshotTree -Snapshots @($other)
		foreach ($record in @(Get-UETemplateProcessDescendants -Index $otherTree.index -RootProcessIds $otherTree.roots)) {
			$otherRunIds[[int]$record.process_id] = $true
		}
	}

	$owned = New-Object 'System.Collections.Generic.List[psobject]'
	$excluded = New-Object 'System.Collections.Generic.List[psobject]'
	$gaps = New-Object 'System.Collections.Generic.List[psobject]'

	foreach ($conflict in @($tree.conflicts)) {
		$gaps.Add([pscustomobject]@{ process_id = [int]$conflict.process_id; parent_process_id = 0; name = [string]$conflict.name; reason = 'snapshot-identity-conflict' })
	}
	if ($tree.roots.Count -eq 0) {
		$gaps.Add([pscustomobject]@{ process_id = 0; parent_process_id = 0; name = ''; reason = 'root-not-recorded' })
	}
	foreach ($rootId in @($tree.roots)) {
		if (-not $tree.index.byId.ContainsKey([int]$rootId)) {
			$gaps.Add([pscustomobject]@{ process_id = [int]$rootId; parent_process_id = 0; name = ''; reason = 'root-not-in-snapshot' })
		}
	}

	$candidates = @(Get-UETemplateProcessDescendants -Index $tree.index -RootProcessIds $tree.roots)
	$runDepths = Get-UETemplateProcessDepths -Index $tree.index -RootProcessIds $tree.roots
	$runOwnedIds = @{}
	foreach ($record in $candidates) { $runOwnedIds[[int]$record.process_id] = $true }

	foreach ($record in $candidates) {
		$id = [int]$record.process_id
		$name = [string]$record.name
		$live = $liveIndex.byId[$id]

		if ($preserveNames.Count -gt 0 -and $preserveNames -contains $name.ToLowerInvariant()) {
			$excluded.Add([pscustomobject]@{ process_id = $id; name = $name; executable_path = $record.executable_path; reason = 'shared-chrome' })
			continue
		}
		if ($tree.boundary -contains $id) {
			$excluded.Add([pscustomobject]@{ process_id = $id; name = $name; executable_path = $record.executable_path; reason = 'boundary-ancestor' })
			continue
		}
		if ($tree.excluded_process_ids -contains $id) {
			$excluded.Add([pscustomobject]@{ process_id = $id; name = $name; executable_path = $record.executable_path; reason = 'snapshot-excluded' })
			continue
		}
		if ($otherRunIds.ContainsKey($id)) {
			$excluded.Add([pscustomobject]@{ process_id = $id; name = $name; executable_path = $record.executable_path; reason = 'other-run-process' })
			continue
		}
		if ($additionalExclude -contains $id) {
			$excluded.Add([pscustomobject]@{ process_id = $id; name = $name; executable_path = $record.executable_path; reason = 'explicit-exclude' })
			continue
		}
		if ([long]$record.creation_utc_ticks -le 0) {
			$gaps.Add([pscustomobject]@{ process_id = $id; parent_process_id = [int]$record.parent_process_id; name = $name; reason = 'creation-time-unknown' })
			continue
		}
		if ($null -ne $live -and -not (Test-UETemplateProcessIdentity -ExpectedRecord $record -LiveRecord $live)) {
			# The recorded identity is gone and this PID now runs a different process. The run-owned
			# process exited, but the snapshot no longer describes the live tree, so the attribution
			# cannot be called verified: report it as a gap and never stop the live stranger.
			$gaps.Add([pscustomobject]@{ process_id = $id; parent_process_id = [int]$record.parent_process_id; name = $name; reason = 'pid-reused-or-identity-mismatch' })
			continue
		}
		$owned.Add([pscustomobject]@{
			process_id         = $id
			parent_process_id  = [int]$record.parent_process_id
			name               = $name
			executable_path    = $record.executable_path
			creation_utc_ticks = [long]$record.creation_utc_ticks
			depth              = [int]$runDepths[$id]
			live               = ($null -ne $live)
		})
	}

	# A live process hanging off a run-owned process but recorded by no snapshot cannot be attributed.
	# It is reported, never stopped, and it keeps the verdict at `unknown`.
	foreach ($record in @(ConvertTo-UETemplateProcessTable -Records $LiveTable)) {
		$id = [int]$record.process_id
		$parentId = [int]$record.parent_process_id
		if ($runOwnedIds.ContainsKey($id)) { continue }
		if ($otherRunIds.ContainsKey($id)) { continue }
		if (-not $runOwnedIds.ContainsKey($parentId)) { continue }
		$parent = $tree.index.byId[$parentId]
		if ($null -eq $parent) { continue }
		if (-not (Test-UETemplateParentLink -ChildRecord $record -ParentRecord $parent)) { continue }
		$gaps.Add([pscustomobject]@{ process_id = $id; parent_process_id = $parentId; name = [string]$record.name; reason = 'live-process-not-in-snapshot' })
	}

	[pscustomobject]@{
		ok                        = $true
		snapshotMissing           = $false
		roots                     = $tree.roots
		writer                    = $tree.writer
		writer_creation_utc_ticks = $tree.writer_creation_utc_ticks
		owned                     = $owned.ToArray()
		excluded                  = $excluded.ToArray()
		gaps                      = $gaps.ToArray()
		conflicts                 = $tree.conflicts
		run_ids                   = $tree.run_ids
		table                     = $tree
	}
}

function Get-UETemplateStopPlan {
	# Pairs each owned record with its current live identity. Only a live PID whose creation time
	# still matches the snapshot is a stop target: a reused PID is somebody else's process.
	param(
		[Parameter(Mandatory)]$Ownership,
		[AllowNull()]$LiveTable,
		[string[]]$PreserveProcessNames = @('chrome')
	)

	if (-not $Ownership.ok) {
		return [pscustomobject]@{ targets = @(); skipped = @(); mode = 'refused' }
	}

	$preserveNames = @($PreserveProcessNames | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
	$liveIndex = Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $LiveTable)
	$plan = New-Object 'System.Collections.Generic.List[psobject]'
	$skipped = New-Object 'System.Collections.Generic.List[psobject]'

	foreach ($record in @($Ownership.owned)) {
		$id = [int]$record.process_id
		$name = [string]$record.name
		$live = $liveIndex.byId[$id]
		if ($preserveNames.Count -gt 0 -and $preserveNames -contains $name.ToLowerInvariant()) {
			$skipped.Add([pscustomobject]@{ process_id = $id; name = $name; reason = 'shared-chrome'; live = ($null -ne $live) })
			continue
		}
		if ($null -eq $live) {
			$skipped.Add([pscustomobject]@{ process_id = $id; name = $name; reason = 'already-exited'; live = $false })
			continue
		}
		if (-not (Test-UETemplateProcessIdentity -ExpectedRecord $record -LiveRecord $live)) {
			$skipped.Add([pscustomobject]@{ process_id = $id; name = $name; reason = 'identity-unknown-or-reused'; live = $true })
			continue
		}
		$plan.Add([pscustomobject]@{
			process_id         = $id
			parent_process_id  = [int]$record.parent_process_id
			name               = $name
			executable_path    = [string]$record.executable_path
			creation_utc_ticks = [long]$record.creation_utc_ticks
			depth              = [int]$record.depth
		})
	}

	# Deepest first, so a parent cannot orphan a child between the listing and the stop.
	$sorted = @($plan | Sort-Object -Property @{ Expression = { [int]$_.depth }; Descending = $true }, @{ Expression = { [long]$_.creation_utc_ticks }; Descending = $true })
	[pscustomobject]@{ targets = $sorted; skipped = $skipped.ToArray(); mode = 'ready' }
}

function Test-UETemplateProcessIdentity {
	# True only when a live process still carries the snapshot's process_id and creation time.
	param($ExpectedRecord, $LiveRecord)

	if ($null -eq $LiveRecord -or $null -eq $ExpectedRecord) { return $false }
	if ([int]$LiveRecord.process_id -ne [int]$ExpectedRecord.process_id) { return $false }
	$expected = [long]$ExpectedRecord.creation_utc_ticks
	$live = [long]$LiveRecord.creation_utc_ticks
	if ($expected -le 0 -or $live -le 0) { return $false }
	($expected -eq $live)
}

function Stop-UETemplateProcessByIdentity {
	# Stops exactly one PID whose identity still matches the snapshot. Never targets a name.
	param([Parameter(Mandatory)]$PlanEntry, [int]$GraceMilliseconds = 3000, [switch]$NoForce)

	$live = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f [int]$PlanEntry.process_id) -ErrorAction SilentlyContinue
	if ($null -eq $live) {
		return [pscustomobject]@{ process_id = [int]$PlanEntry.process_id; stopped = $false; reason = 'already-exited' }
	}
	$liveRecord = New-UETemplateProcessRecord -Source $live
	if (-not (Test-UETemplateProcessIdentity -ExpectedRecord $PlanEntry -LiveRecord $liveRecord)) {
		return [pscustomobject]@{ process_id = [int]$PlanEntry.process_id; stopped = $false; reason = 'identity-changed-before-stop' }
	}
	try {
		if ($NoForce) { Stop-Process -Id ([int]$PlanEntry.process_id) -ErrorAction Stop } else { Stop-Process -Id ([int]$PlanEntry.process_id) -Force -ErrorAction Stop }
	} catch {
		return [pscustomobject]@{ process_id = [int]$PlanEntry.process_id; stopped = $false; reason = ('stop-failed: ' + $_.Exception.Message) }
	}

	$deadline = [datetime]::UtcNow.AddMilliseconds([Math]::Max(0, $GraceMilliseconds))
	while ([datetime]::UtcNow -lt $deadline) {
		$after = Get-CimInstance -ClassName Win32_Process -Filter ("ProcessId = {0}" -f [int]$PlanEntry.process_id) -ErrorAction SilentlyContinue
		if ($null -eq $after) {
			return [pscustomobject]@{ process_id = [int]$PlanEntry.process_id; stopped = $true; reason = 'exited' }
		}
		$afterRecord = New-UETemplateProcessRecord -Source $after
		if (-not (Test-UETemplateProcessIdentity -ExpectedRecord $PlanEntry -LiveRecord $afterRecord)) {
			return [pscustomobject]@{ process_id = [int]$PlanEntry.process_id; stopped = $true; reason = 'pid-reused-after-stop' }
		}
		Start-Sleep -Milliseconds 100
	}
	[pscustomobject]@{ process_id = [int]$PlanEntry.process_id; stopped = $false; reason = 'still-alive-after-grace' }
}

function Get-UETemplateResidualProcesses {
	# Residual = run-owned processes still alive with the recorded identity.
	param([Parameter(Mandatory)]$Ownership, [AllowNull()]$LiveTable, [string[]]$PreserveProcessNames = @('chrome'))

	if (-not $Ownership.ok) { return @() }
	$preserveNames = @($PreserveProcessNames | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() })
	$liveIndex = Get-UETemplateProcessIndex -Table @(ConvertTo-UETemplateProcessTable -Records $LiveTable)
	$residual = New-Object 'System.Collections.Generic.List[psobject]'
	foreach ($record in @($Ownership.owned)) {
		$id = [int]$record.process_id
		$name = [string]$record.name
		if ($preserveNames.Count -gt 0 -and $preserveNames -contains $name.ToLowerInvariant()) { continue }
		$live = $liveIndex.byId[$id]
		if (Test-UETemplateProcessIdentity -ExpectedRecord $record -LiveRecord $live) {
			$residual.Add([pscustomobject]@{ process_id = $id; name = $name; executable_path = [string]$record.executable_path })
		}
	}
	$residual.ToArray()
}

function Get-UETemplateFileSha256 {
	# Get-FileHash is a PowerShell module cmdlet whose resolution depends on PSModulePath; on some
	# hosts Windows PowerShell 5.1 cannot resolve it. Hashing through .NET works on both 5.1 and 7.
	param([Parameter(Mandatory)][string]$Path)

	$resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
	$stream = [System.IO.File]::OpenRead($resolved)
	try {
		$sha = [System.Security.Cryptography.SHA256]::Create()
		try {
			$bytes = $sha.ComputeHash($stream)
		} finally { $sha.Dispose() }
	} finally { $stream.Dispose() }
	return (($bytes | ForEach-Object { $_.ToString('X2') }) -join '')
}

function Read-UETemplateJsonFile {
	param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Description)

	if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
		throw ("{0} is missing: {1}" -f $Description, $Path)
	}
	$resolved = (Resolve-Path -LiteralPath $Path).ProviderPath
	$raw = [System.IO.File]::ReadAllText($resolved)
	if ([string]::IsNullOrWhiteSpace($raw)) { throw ("{0} is empty: {1}" -f $Description, $Path) }
	try {
		$data = ConvertFrom-Json -InputObject $raw
	} catch {
		throw ("{0} is not valid JSON ({1}): {2}" -f $Description, $_.Exception.Message, $Path)
	}
	if ($null -eq $data) { throw ("{0} parsed to null: {1}" -f $Description, $Path) }
	$data
}

function Write-UETemplateJsonFile {
	param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value, [switch]$Exclusive)

	$parent = Split-Path -Parent $Path
	if ($parent -and -not (Test-Path -LiteralPath $parent -PathType Container)) {
		[System.IO.Directory]::CreateDirectory($parent) | Out-Null
	}
	$json = ConvertTo-Json -InputObject $Value -Depth 12
	$text = $json + [Environment]::NewLine
	if ($Exclusive) {
		$stream = [System.IO.FileStream]::new($Path, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
		try {
			$writer = New-Object System.IO.StreamWriter($stream, [System.Text.UTF8Encoding]::new($false))
			try { $writer.Write($text) } finally { $writer.Dispose() }
		} finally { $stream.Dispose() }
		return
	}
	[System.IO.File]::WriteAllText($Path, $text, [System.Text.UTF8Encoding]::new($false))
}
