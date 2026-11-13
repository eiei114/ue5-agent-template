[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('ue-integration-review-' + [guid]::NewGuid().ToString('N'))
$pwsh = (Get-Process -Id $PID).Path
function Assert-Review([bool]$Value, [string]$Message) {
    if (-not $Value) { throw "ASSERT FAILED: $Message" }
}
function Import-TestFunction([string]$Path, [string]$Name) {
    $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
    $definition = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $Name }, $true)
    Assert-Review ($null -ne $definition) "shipped helper exists: $Name"
    # Import only the named trusted repository function, never the suite's executable body.
    return $definition.Extent.Text
}
try {
    [IO.Directory]::CreateDirectory($scratch) | Out-Null
    Invoke-Expression (Import-TestFunction (Join-Path $PSScriptRoot 'Test-UETemplateScaffold.ps1') 'Get-CppCodeOnly')
    $raw = 'const char* text = R"tag(embedded " IMPLEMENT_MODULE(FDefaultGameModuleImpl, MulticaOnlineStarter))tag";'
    Assert-Review (-not (Get-CppCodeOnly $raw).Contains('IMPLEMENT_MODULE')) 'C++ raw string cannot spoof an entrypoint'
    Write-Output 'PASS: raw string, including embedded quote, cannot spoof IMPLEMENT_MODULE'

    $macScript = Join-Path $PSScriptRoot 'Test-UEMacHostRequirements.ps1'
    foreach ($case in @(
        @{OS='unknown 15.6'; Xcode='26.1.1'; Expected=2},
        @{OS='15.6'; Xcode='26.3.1'; Expected=2},
        @{OS='27.0'; Xcode='26.1.1'; Expected=2},
        @{OS='15.6'; Xcode='26.1.1'; Expected=0}
    )) {
        $output = @(& $pwsh -NoProfile -File $macScript -MacOSVersion $case.OS -XcodeVersion $case.Xcode -ProcessorFamily 'Apple M3 Pro' -MemoryGB 32 -MetalSupported yes)
        Assert-Review ($LASTEXITCODE -eq $case.Expected) ("strict Mac observation $($case.OS) / $($case.Xcode): " + ($output -join '; '))
    }
    $empty = @(& $pwsh -NoProfile -File $macScript)
    Assert-Review ($LASTEXITCODE -eq 2) 'no observations return unverified, not failure'
    Write-Output 'PASS: strict Mac observations, exact Apple rows, upper OS bound, full chip name and empty inputs'

    $project = Join-Path $scratch 'Project'
    $delivery = Join-Path $project 'Out/run_review'
    [IO.Directory]::CreateDirectory($delivery) | Out-Null
    foreach ($group in @('Input','InputActions')) {
        [IO.Directory]::CreateDirectory((Join-Path $project "Content/$group")) | Out-Null
        [IO.File]::WriteAllText((Join-Path $project "Content/$group/fixture.uasset"), 'self-authored placeholder bytes')
    }
    $credits = Join-Path $delivery 'CREDITS.md'
    $header = "| asset | origin | bundle | project path |`n|---|---|---|---|`n"
    [IO.File]::WriteAllText($credits, ($header + '| InputActions | original | generated-only | Content/InputActions |'))
    $audit = Join-Path $PSScriptRoot 'Measure-UECreditsInventory.ps1'
    $out = @(& $pwsh -NoProfile -File $audit -Target $project)
    Assert-Review ($LASTEXITCODE -eq 1) 'InputActions cannot cover Input by substring'
    [IO.File]::WriteAllText($credits, ($header + "~~~markdown`n| Input | original | generated-only | Content/Input |`n| InputActions | original | generated-only | Content/InputActions |`n~~~`n"))
    $out = @(& $pwsh -NoProfile -File $audit -Target $project)
    Assert-Review ($LASTEXITCODE -eq 1) 'tilde-fenced examples cannot count as credits'
    [IO.Directory]::CreateDirectory((Join-Path $delivery 'Content')) | Out-Null
    foreach ($target in @($project,$delivery)) {
        $out = @(& $pwsh -NoProfile -File $audit -Target $target)
        Assert-Review ($LASTEXITCODE -eq 2) 'ambiguous Content is rejected from both entrypoints'
    }
    Write-Output 'PASS: complete credits groups, tilde fences, symmetric Content ambiguity'

    $contract = Join-Path $scratch 'Contract'
    foreach ($relative in @('AGENTS.md','docs/06-delivery.md','templates/README.md','templates/QA.md','templates/CREDITS.md','templates/DELIVERY.json')) {
        $target = Join-Path $contract $relative
        [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repoRoot $relative) -Destination $target
    }
    $suite = Join-Path $PSScriptRoot 'Test-UETemplateScaffold.ps1'
    Invoke-Expression (Import-TestFunction $suite 'Add-SetDifference')
    Invoke-Expression (Import-TestFunction $suite 'Get-DeliveryContractProblems')
    Assert-Review (@(Get-DeliveryContractProblems $contract).Count -eq 0) 'original delivery contract passes'
    $manifestPath = Join-Path $contract 'templates/DELIVERY.json'
    $manifest = [IO.File]::ReadAllText($manifestPath)
    [IO.File]::WriteAllText($manifestPath, '')
    Assert-Review ((@(Get-DeliveryContractProblems $contract) -join '; ').Contains('empty or null')) 'empty manifest cannot bypass field checks'
    $optional = $manifest | ConvertFrom-Json
    $optional.readme_receipt.required = $false
    [IO.File]::WriteAllText($manifestPath, ($optional | ConvertTo-Json -Depth 20))
    Assert-Review ((@(Get-DeliveryContractProblems $contract) -join '; ').Contains('must remain required')) 'README receipt cannot become optional'
    [IO.File]::WriteAllText($manifestPath, $manifest)
    $deliveryDoc = Join-Path $contract 'docs/06-delivery.md'
    $text = [IO.File]::ReadAllText($deliveryDoc)
    $swapped = $text.Replace('templates/README.md','templates/swap.md').Replace('templates/QA.md','templates/README.md').Replace('templates/swap.md','templates/QA.md')
    [IO.File]::WriteAllText($deliveryDoc, $swapped)
    Assert-Review ((@(Get-DeliveryContractProblems $contract) -join '; ').Contains('does not place')) 'swapping template cells cannot preserve the delivery contract'
    Write-Output 'PASS: empty manifest, optional receipt and swapped delivery templates are rejected'

    $fixture = Join-Path $scratch 'Publish'
    [IO.Directory]::CreateDirectory((Join-Path $fixture 'Production')) | Out-Null
    & git init --quiet $fixture
    & git -C $fixture config user.name 'Integration Fixture'
    & git -C $fixture config user.email 'fixture@example.invalid'
    [IO.File]::WriteAllText((Join-Path $fixture 'Production/PLACEHOLDER.md'), 'placeholder')
    [IO.File]::WriteAllText((Join-Path $fixture 'README.md'), 'fixture')
    # No actual credentials: test filename only, with self-authored placeholder text.
    [IO.File]::WriteAllText((Join-Path $fixture 'auth.json'), 'placeholder, not credentials')
    & git -C $fixture add --all
    & git -C $fixture commit --quiet -m 'fixture'
    & git -C $fixture rm --quiet --cached auth.json
    $publish = Join-Path $PSScriptRoot 'Test-UETemplatePublishSurface.ps1'
    $out = @(& $pwsh -NoProfile -File $publish -RepoRoot $fixture -PushRevision HEAD)
    Assert-Review ($LASTEXITCODE -eq 1 -and ($out -join '; ').Contains('history: auth.json')) 'staging credential removal cannot hide pushed history'
    & git -C $fixture commit --quiet -m 'remove placeholder credential-shaped file'
    [IO.File]::WriteAllText((Join-Path $fixture 'README.md'), '[guide](missing.md "Guide")')
    & git -C $fixture add README.md
    [IO.File]::WriteAllText((Join-Path $fixture 'README.md'), 'unstaged fix must not hide indexed broken link')
    $out = @(& $pwsh -NoProfile -File $publish -RepoRoot $fixture)
    Assert-Review ($LASTEXITCODE -eq 1 -and ($out -join '; ').Contains('missing.md')) 'audit uses indexed Markdown, including title-bearing links'
    Write-Output 'PASS: push history remains visible and indexed Markdown wins over unstaged worktree'
} finally {
    if (Test-Path -LiteralPath $scratch) { Remove-Item -LiteralPath $scratch -Recurse -Force }
}
Write-Output 'INTEGRATION REVIEW SUITE PASSED'
# Negative child-process probes deliberately leave LASTEXITCODE=1. Return an explicit
# success code when invoked in the same PowerShell process by CI, not only via -File.
exit 0
