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

  One GitHub Release v<version> carries both platforms: the APKs, and the
  Windows installer and zip when release\windows\v<version>\ has them. Its
  notes are release\notes\github-v<version>.md, or the phone's notes without
  one. Publish it first (-SkipR2), then send phones to it (-SkipGitHub).

  With -Windows, uploads the Windows installer to R2 only, for in-app updates
  (windows/v<version>/, then latest-windows.json last; newest 3 kept). Notes:
  release\notes\windows-v<version>.md.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -SkipGitHub
  powershell -ExecutionPolicy Bypass -File scripts\publish.ps1 -Windows
#>
# -Replace: publish the same version again (only when the user asked to
# overwrite it): the APKs and latest.json are replaced, the GitHub Release
# gets the new APKs and notes.
param([switch]$SkipGitHub, [switch]$SkipR2, [switch]$Replace, [switch]$Windows, [string]$WindowsVersion)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
# Node tools and gh get an ASCII path through the junction.
$root = 'D:\dev\ouoplayer'
$bucket = 'ouoplayer-updates'
$keep = 3
$abis = 'arm64-v8a', 'armeabi-v7a', 'x86_64'

function Wrangler {
    & npx.cmd --yes wrangler@4 @args
    if ($LASTEXITCODE -ne 0) { throw "wrangler $($args -join ' ') failed" }
}
function Put($key, $file, $type) { Wrangler r2 object put "$bucket/$key" --file $file --content-type $type --remote }

if ($Windows) {
    if (-not $WindowsVersion) {
        $WindowsVersion = ((Select-String -Path (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1).Matches[0].Groups[1].Value -split '\+')[0]
    }
    $tag = "windows-v$WindowsVersion"
    $dir = Join-Path $root "release\windows\v$WindowsVersion"
    $setupName = "OuOPlayer-$WindowsVersion-windows-setup.exe"
    $setup = Join-Path $dir $setupName
    $notesFile = Join-Path $root "release\notes\$tag.md"
    foreach ($f in $setup, $notesFile) {
        if (-not (Test-Path $f)) { throw "Missing $f" }
    }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) "ouo-publish-$tag"
    New-Item -ItemType Directory -Force $tmp | Out-Null

    if (-not $SkipR2) {
        $versionsFile = Join-Path $tmp 'versions-windows.json'
        $versions = @()
        # Missing on the first publish; that error is expected.
        $ErrorActionPreference = 'Continue'
        & npx.cmd --yes wrangler@4 r2 object get "$bucket/versions-windows.json" --file $versionsFile --remote *> $null
        $ErrorActionPreference = 'Stop'
        if ($LASTEXITCODE -eq 0 -and (Test-Path $versionsFile)) { $versions = @(Get-Content $versionsFile -Raw | ConvertFrom-Json | ForEach-Object { $_ }) }
        if (($versions -contains $WindowsVersion) -and -not $Replace) { throw "$tag is already on the update server." }

        $key = "windows/v$WindowsVersion/$setupName"
        Write-Host "== Uploading $setupName" -ForegroundColor Cyan
        Put $key $setup 'application/octet-stream'
        $file = [ordered]@{ path = $key; sha256 = (Get-FileHash $setup -Algorithm SHA256).Hash.ToLower(); size = (Get-Item $setup).Length }
        $latest = [ordered]@{
            version  = $WindowsVersion
            notes    = (Get-Content $notesFile -Raw -Encoding UTF8).Trim()
            released = (Get-Date -Format 'yyyy-MM-dd')
            apks     = [ordered]@{ windows = $file }
        }
        $latestFile = Join-Path $tmp 'latest-windows.json'
        [IO.File]::WriteAllText($latestFile, ($latest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        Write-Host '== Uploading latest-windows.json' -ForegroundColor Cyan
        Put 'latest-windows.json' $latestFile 'application/json; charset=utf-8'

        if ($versions -notcontains $WindowsVersion) { $versions = @($versions) + $WindowsVersion }
        $old = @()
        if ($versions.Count -gt $keep) { $old = $versions[0..($versions.Count - $keep - 1)] }
        foreach ($v in $old) {
            Write-Host "== Removing Windows v$v from R2" -ForegroundColor DarkGray
            & npx.cmd --yes wrangler@4 r2 object delete "$bucket/windows/v$v/OuOPlayer-$v-windows-setup.exe" --remote
        }
        $versions = @($versions | Where-Object { $old -notcontains $_ })
        [IO.File]::WriteAllText($versionsFile, (ConvertTo-Json @($versions)), [Text.UTF8Encoding]::new($false))
        Put 'versions-windows.json' $versionsFile 'application/json'
    }

    Remove-Item -Recurse -Force $tmp
    Write-Host "== Published OuOPlayer $tag" -ForegroundColor Green
    exit 0
}

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
    if (($versions -contains $version) -and -not $Replace) { throw "$tag is already on the update server." }

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
    if ($versions -notcontains $version) { $versions = @($versions) + $version }
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
    $files = @(foreach ($abi in $abis) { Join-Path $apkDir "OuOPlayer-$version-$abi.apk" })
    $winDir = Join-Path $root "release\windows\$tag"
    foreach ($name in "OuOPlayer-$version-windows-setup.exe", "OuOPlayer-$version-windows-x64.zip") {
        $file = Join-Path $winDir $name
        if (Test-Path $file) { $files += $file }
    }
    $githubNotes = Join-Path $root "release\notes\github-$tag.md"
    if (-not (Test-Path $githubNotes)) { $githubNotes = $notesFile }
    if ($Replace) {
        gh release upload $tag @files --repo HowardWang818/OuOPlayer --clobber
        if ($LASTEXITCODE -ne 0) { throw 'gh release upload failed' }
        gh release edit $tag --repo HowardWang818/OuOPlayer --notes-file $githubNotes
        if ($LASTEXITCODE -ne 0) { throw 'gh release edit failed' }
    } else {
        gh release create $tag @files --repo HowardWang818/OuOPlayer --title "OuOPlayer $version" --notes-file $githubNotes --verify-tag
        if ($LASTEXITCODE -ne 0) { throw 'gh release create failed' }
    }
}

Remove-Item -Recurse -Force $tmp
Write-Host "== Published OuOPlayer $tag" -ForegroundColor Green
