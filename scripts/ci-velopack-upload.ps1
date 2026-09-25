<#
.SYNOPSIS
    XIVLauncher Velopack build + GitHub Releases publish script.
    Called by CI workflow on tag push.

.DESCRIPTION
    1. Download previous release feed via GitHub Releases (for delta generation)
    2. Pack new release via vpk
    3. Pull remote releases.win.json from GitHub, merge with local
    4. Trim to latest N versions
    5. Create a draft GitHub Release, attach nupkgs + merged feed, then publish as latest

.ENVIRONMENT
    GH_TOKEN      - GitHub Token (read/write releases)
    GITHUB_REF    - Git ref that triggered the workflow
    GITHUB_REPOSITORY - Repository full name (owner/repo)
#>

param(
    [string]$Channel          = 'win',
    [string]$PackId           = 'XIVLauncherCN',
    [string]$PackDir          = '.\bin\win-x64',
    [string]$OutputDir        = '.\Releases',
    [string]$MainExe          = 'XIVLauncherCN.exe',
    [string]$PackAuthors      = 'OmenCorp',
    [string]$ReleaseNotesPath = '.\XIVLauncher\Resources\CHANGELOG.txt',
    [string]$IconPath         = '.\XIVLauncher\Resources\dalamud_icon.ico',
    [string]$SplashPath       = '.\XIVLauncher\Resources\logo.png',
    [string]$Framework        = 'net10.0-x64-desktop',
    [int]$MaxVersions         = 10
)

$ErrorActionPreference = 'Stop'

function Write-Step([string]$Msg) {
    Write-Host ">>> $Msg"
}

if (-not $env:GITHUB_REPOSITORY) { throw 'GITHUB_REPOSITORY is required' }

# ---- Derived GitHub URLs ----
$feedBaseUrl  = "https://github.com/$env:GITHUB_REPOSITORY/releases/latest/download"
$assetBaseUrl = "https://github.com/$env:GITHUB_REPOSITORY/releases/download"

# ---- Extract version ----
$refver = $env:GITHUB_REF -replace '.*/'
Write-Step "Release version: $refver"

# ---- Ensure tools ----
if (-not (Get-Command vpk -ErrorAction SilentlyContinue)) {
    dotnet tool install -g vpk
}

New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

# ---- 1. Download previous release feed (for delta) ----
Write-Step 'Downloading previous release feed...'
try {
    vpk download http --url $feedBaseUrl --channel $Channel --timeout 30
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "  No previous release feed available (first release?), continuing without delta."
    }
}
catch {
    Write-Warning "  Failed to download previous release feed (first release?), continuing without delta. $_"
}

# ---- 2. Pack new release ----
Write-Step "Packing release $refver..."
$packArgs = @(
    '-u', $PackId,
    '-v', $refver,
    '-p', $PackDir,
    '-o', $OutputDir,
    '-e', $MainExe,
    '--channel', $Channel,
    '--packAuthors', $PackAuthors,
    '--releaseNotes', $ReleaseNotesPath,
    '--icon', $IconPath,
    '--splashImage', $SplashPath,
    '--framework', $Framework,
    '--noInst'
)
& vpk pack @packArgs

# ---- 3. Read local generated entries ----
$localJson   = Get-Content -LiteralPath "$OutputDir\releases.win.json" -Encoding utf8 | ConvertFrom-Json
$localAssets = @($localJson.Assets)
Write-Step "Local new entries: $($localAssets.Count)"

# ---- 4. Pull remote releases.win.json from GitHub ----
$remoteAssets = @()
try {
    $cacheBust = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $remoteObj = Invoke-RestMethod -Uri "$feedBaseUrl/releases.win.json?t=$cacheBust" -ErrorAction Stop
    $remoteAssets = @($remoteObj.Assets)
    Write-Step "Remote existing entries: $($remoteAssets.Count)"
}
catch {
    Write-Host "  No remote releases.win.json yet (first release). ($_)"
}

# ---- 5. Normalize FileName to absolute GitHub URLs + merge (dedup by URL, local wins) ----
$merged = @{}
foreach ($a in ($remoteAssets + $localAssets)) {
    if ($a.FileName -notmatch '^https?://') {
        $a.FileName = "$assetBaseUrl/$($a.Version)/$($a.FileName)"
    }
    $merged[$a.FileName] = $a
}
$mergedList = @($merged.Values)

# ---- 6. Keep latest N versions ----
$versionMap = @{}
foreach ($a in $mergedList) {
    $v = $a.Version -replace '^v', ''
    if (-not $versionMap.ContainsKey($v)) { $versionMap[$v] = @() }
    $versionMap[$v] += $a
}
$sortedVersions = $versionMap.Keys | Sort-Object { [Version]$_ } -Descending
$keepVersions   = $sortedVersions | Select-Object -First $MaxVersions
$keepSet        = @{}
foreach ($v in $keepVersions) { $keepSet[$v] = $true }

Write-Step "Keeping versions ($($keepVersions.Count)): $($keepVersions -join ', ')"

$keepAssets = @($mergedList | Where-Object { $v = $_.Version -replace '^v', ''; $keepSet.ContainsKey($v) })
$sortedKeep = $keepAssets | Sort-Object { [Version]($_.Version -replace '^v', '') } -Descending

# ---- 7. Build merged feed (correct asset file names) ----
$feedDir = "$OutputDir\feed"
New-Item -ItemType Directory -Path $feedDir -Force | Out-Null

$releaseJson = @{ Assets = @($sortedKeep) } | ConvertTo-Json -Depth 3
$releaseJsonPath = "$feedDir\releases.win.json"
$releaseJson | Set-Content -LiteralPath $releaseJsonPath -Encoding utf8NoBOM

$releasesContent = ($sortedKeep | ForEach-Object { "$($_.SHA1) $($_.FileName) $($_.Size)" }) -join "`n"
$releasesPath = "$feedDir\RELEASES"
$releasesContent | Set-Content -LiteralPath $releasesPath -Encoding utf8NoBOM -NoNewline

Write-Host "Merged feed: $($keepAssets.Count) nupkgs, $($keepVersions.Count) versions."

# ---- 8. Create draft GitHub Release (attach this version's binaries) ----
Write-Step 'Creating draft GitHub Release...'
$portableZip = Get-ChildItem "$OutputDir\*-Portable.zip" -File | Select-Object -First 1
$releaseNotes = Get-Content -LiteralPath $ReleaseNotesPath -Encoding utf8 -Raw

$ghArgs = @(
    'release', 'create', $refver,
    '--draft',
    '--title', "Release $refver",
    '--notes', $releaseNotes
)
if ($portableZip) {
    $ghArgs += $portableZip.FullName
}
Get-ChildItem "$OutputDir\*$refver*.nupkg" -File | ForEach-Object {
    $ghArgs += $_.FullName
}

gh @ghArgs --repo $env:GITHUB_REPOSITORY
if ($LASTEXITCODE -ne 0) {
    Write-Warning "  GitHub Release creation failed (may already exist from a previous run), continuing. (exit=$LASTEXITCODE)"
}
else {
    Write-Host "  Draft release created: $refver"
}

# ---- 9. Upload merged feed to the release ----
Write-Step 'Uploading merged feed...'
gh release upload $refver $releaseJsonPath $releasesPath --repo $env:GITHUB_REPOSITORY --clobber
if ($LASTEXITCODE -ne 0) { throw 'Upload of merged feed failed' }

# ---- 10. Publish as latest ----
Write-Step 'Publishing release as latest...'
gh release edit $refver --draft=false --latest --repo $env:GITHUB_REPOSITORY
if ($LASTEXITCODE -ne 0) { throw 'Publishing release failed' }

Write-Host "Published: $refver ($($keepAssets.Count) nupkgs, $($keepVersions.Count) versions)"
