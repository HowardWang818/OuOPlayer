<#
.SYNOPSIS
  Publishes an already built Android release (release\android\v<version>\)
  for in-app updates, and as a GitHub Release on the private repository.

.DESCRIPTION
  Run only after the version was tested, committed and tagged (v<version>
  pushed to origin) - and only when the user said to publish.
    1. Uploads the APKs to the private R2 bucket (through the user's own
       `npx wrangler login`), then latest.json last, so phones never see a
       half-uploaded version.
    2. Keeps the newest 3 versions on R2 and deletes older ones there (the
       local release\ folders are never touched).
    3. Creates the GitHub Release v<version> with the APKs (`gh`).
  Release notes come from release\notes\v<version>.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -SkipGitHub
#>
param([switch]$SkipGitHub, [switch]$SkipR2)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
# Node tools and gh get an ASCII path through the junction.
$root = 'D:\dev\ouoplayer'
$bucket = 'ouoplayer-updates'
$keep = 3
$abis = 'arm64-v8a', 'armeabi-v7a', 'x86_64'

$line = Select-String -Path (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1
$full = $line.Matches[0].Groups[1].Value
$version, $build = $full -split '\+'
$tag = "v$version"
$apkDir = Join-Path $root "release\android\$tag"
$notesFile = Join-Path $root "release\notes\$tag.md"

foreach ($abi in $abis) {
    if (-not (Test-Path (Join-Path $apkDir "OuOPlayer-$version-$abi.apk"))) { throw "Missing APK for $abi in $apkDir - run release.ps1 first." }
}
if (-not (Test-Path $notesFile)) { throw "Missing release notes: $notesFile" }
$notes = (Get-Content $notesFile -Raw -Encoding UTF8).Trim()
git -C $project fetch --tags origin --quiet
if (-not (git -C $project ls-remote --tags origin "refs/tags/$tag")) { throw "Tag $tag is not on origin yet - commit, tag and push first." }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "ouo-publish-$version"
New-Item -ItemType Directory -Force $tmp | Out-Null

function Wrangler {
    & npx.cmd --yes wrangler@4 @args
    if ($LASTEXITCODE -ne 0) { throw "wrangler $($args -join ' ') failed" }
}
function Put($key, $file, $type) { Wrangler r2 object put "$bucket/$key" --file $file --content-type $type --remote }

if (-not $SkipR2) {
    # Versions already up there (newest last).
    $versionsFile = Join-Path $tmp 'versions.json'
    $versions = @()
    # Missing on the first publish; that error is expected.
    $ErrorActionPreference = 'Continue'
    & npx.cmd --yes wrangler@4 r2 object get "$bucket/versions.json" --file $versionsFile --remote *> $null
    $ErrorActionPreference = 'Stop'
    # (Windows PowerShell returns a JSON array as one object: unrolled with ForEach.)
    if ($LASTEXITCODE -eq 0 -and (Test-Path $versionsFile)) { $versions = @(Get-Content $versionsFile -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }
    if ($versions -contains $version) { throw "$tag is already on the update server." }

    $apks = [ordered]@{}
    foreach ($abi in $abis) {
        $name = "OuOPlayer-$version-$abi.apk"
        $file = Join-Path $apkDir $name
        Write-Host "== Uploading $name" -ForegroundColor Cyan
        Put "$tag/$name" $file 'application/vnd.android.package-archive'
        $apks[$abi] = [ordered]@{
            path   = "$tag/$name"
            sha256 = (Get-FileHash $file -Algorithm SHA256).Hash.ToLower()
            size   = (Get-Item $file).Length
        }
    }

    $latest = [ordered]@{ version = $version; build = [int]$build; notes = $notes; released = (Get-Date -Format 'yyyy-MM-dd'); apks = $apks }
    $latestFile = Join-Path $tmp 'latest.json'
    [IO.File]::WriteAllText($latestFile, ($latest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    Write-Host '== Uploading latest.json' -ForegroundColor Cyan
    Put 'latest.json' $latestFile 'application/json; charset=utf-8'

    # Only the newest versions stay on R2.
    $versions = @($versions) + $version
    $old = @()
    if ($versions.Count -gt $keep) { $old = $versions[0..($versions.Count - $keep - 1)] }
    foreach ($v in $old) {
        foreach ($abi in $abis) {
            Write-Host "== Removing v$v $abi from R2" -ForegroundColor DarkGray
            & npx.cmd --yes wrangler@4 r2 object delete "$bucket/v$v/OuOPlayer-$v-$abi.apk" --remote
        }
    }
    $versions = @($versions | Where-Object { $old -notcontains $_ })
    [IO.File]::WriteAllText($versionsFile, (ConvertTo-Json @($versions)), [Text.UTF8Encoding]::new($false))
    Put 'versions.json' $versionsFile 'application/json'
}

if (-not $SkipGitHub) {
    Write-Host "== GitHub Release $tag" -ForegroundColor Cyan
    $files = foreach ($abi in $abis) { Join-Path $apkDir "OuOPlayer-$version-$abi.apk" }
    gh release create $tag @files --repo HowardWang818/OuOPlayer --title "OuOPlayer $version" --notes-file $notesFile --verify-tag
    if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }
}

Remove-Item -Recurse -Force $tmp
Write-Host "== Published OuOPlayer $tag" -ForegroundColor Green
