# Dot-sourced helper. The one definition of what a `project_differences` value may be.
#
# `template-lock.json` is a reproducibility artifact, so a recorded project difference is data that
# travels with the delivered project. Both writers of that field (the generator at generation time and
# scripts/Update-UETemplateProjectDifference.ps1 after generation) call this function, so a value is
# accepted or rejected by the same rule whichever path recorded it. The contract is written once, in
# docs/07-architecture.md (the "project_differences contract" section).
#
# Format: `<label>: <value>`. The label is 2-40 characters of ASCII letters, digits, space, `_`, `.`
# and `-`, starts with a letter and does not end with a space. One space follows the colon, then the
# value. A label of at least two characters keeps `C:\...` from reading as a label plus a path.
# Stop conditions (the value is rejected, never repaired):
#   - a control character, including a newline or tab (anywhere in the value)
#   - more than 200 characters after trimming
#   - a host-absolute path: a drive path (`C:\`, `C:/`) at the start or after a space or colon, a
#     leading `/`, `\` or UNC `\\`, or a UNC path embedded after a space
#   - a parent-directory segment (`..` between path separators, spaces or the label colon)
#   - anything that does not match the `<label>: <value>` format
# Unreal package paths such as `/Game/Maps/L_Hero` are fine as the *value* of a label; only a value
# that is itself a host path is refused. Empty and whitespace-only values are dropped (as before).

function Get-UETemplateProjectDifferenceProblem {
	param([AllowNull()][string]$Value)
	if ($null -eq $Value) { return $null }
	if ($Value -cmatch '[\x00-\x1F\x7F-\x9F\u2028\u2029]') {
		return 'contains a control character (newline, tab or other non-printing character)'
	}
	if ($Value.Length -gt 200) {
		return ('is {0} characters long; the limit is 200' -f $Value.Length)
	}
	if ($Value -cmatch '^[A-Za-z]:' -or $Value -cmatch '^[\\/]') {
		return 'starts like a host-absolute path (drive letter, leading slash or UNC)'
	}
	if ($Value -cmatch '(?<![A-Za-z0-9])[A-Za-z]:[\\/]' -or $Value -cmatch '(^|\s)\\\\') {
		return 'contains a host-absolute path (drive path or UNC)'
	}
	if ($Value -cmatch '(^|[\\/\s:])\.\.($|[\\/\s])') {
		return 'contains a parent-directory segment ("..")'
	}
	if ($Value -cnotmatch '^[A-Za-z][A-Za-z0-9 _.-]{0,38}[A-Za-z0-9_.-]: \S') {
		return 'does not match the "<label>: <value>" format (label of 2-40 ASCII characters, one space after the colon, a non-empty value)'
	}
	return $null
}

function Format-UETemplateProjectDifferenceForMessage([string]$Value) {
	$shown = $Value
	if ($shown.Length -gt 60) { $shown = $shown.Substring(0, 60) + '...' }
	$shown = [regex]::Replace($shown, '[\x00-\x1F\x7F-\x9F\u2028\u2029]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
	return '"' + $shown + '"'
}

function ConvertTo-UETemplateProjectDifferences {
	# Trim, drop empty, validate every value, remove duplicates, Ordinal sort. Throws, naming each
	# rejected value, when any value breaks the contract: a partly valid list is never returned.
	param([AllowNull()][AllowEmptyCollection()][string[]]$Values)
	$set = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
	$problems = New-Object System.Collections.Generic.List[string]
	foreach ($value in @($Values)) {
		if ($null -eq $value) { continue }
		$normalized = $value.Trim()
		if ([string]::IsNullOrWhiteSpace($normalized)) { continue }
		$problem = Get-UETemplateProjectDifferenceProblem $normalized
		if ($null -ne $problem) {
			$problems.Add(('{0} {1}' -f (Format-UETemplateProjectDifferenceForMessage $normalized), $problem))
			continue
		}
		$null = $set.Add($normalized)
	}
	if ($problems.Count -gt 0) {
		throw ('Project difference check stopped: {0} value(s) break the project_differences contract (docs/07-architecture.md), so nothing was written. {1}' -f $problems.Count, ($problems -join '; '))
	}
	[string[]]$result = @($set)
	[Array]::Sort($result, [System.StringComparer]::Ordinal)
	return $result
}
