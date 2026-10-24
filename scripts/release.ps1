<#
.SYNOPSIS
  Builds OuOPlayer and copies the results into release\android\v<version>\
  (and release\windows\v<version>\ with -Windows).

.DESCRIPTION
  Development currently focuses on Android, so only the APKs are built by
  default. Pass -Windows (only when asked for) to also build the Windows app.
  The version comes from pubspec.yaml ("version: 1.0.0+1" -> v1.0.0).
  Bump it there before releasing; an existing version folder is never
  overwritten unless -Force is given.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\release.ps1
  powershell -ExecutionPolicy Bypass -File scripts\release.ps1 -Windows
#>
param([switch]$Windows, [switch]$Force)

$ErrorActionPreference = 'Stop'
$project = Split-Path -Parent $PSScriptRoot
# Flutter tooling breaks on the non-ASCII project path, so build through the junction.
$buildRoot = 'D:\dev\ouoplayer'
$env:Path = "D:\dev\flutter\bin;$env:Path"
$env:ANDROID_HOME = 'D:\dev\android-sdk'

$line = Select-String -Path (Join-Path $project 'pubspec.yaml') -Pattern '^version:\s*(\S+)' | Select-Object -First 1
if (-not $line) { throw 'version not found in pubspec.yaml' }
$full = $line.Matches[0].Groups[1].Value
$version = ($full -split '\+')[0]
$tag = "v$version"

$apkDir = Join-Path $project "release\android\$tag"
$winDir = Join-Path $project "release\windows\$tag"
$targets = @($apkDir)
if ($Windows) { $targets += $winDir }
foreach ($d in $targets) {
    if ((Test-Path $d) -and -not $Force) {
        throw "$d already exists. Bump the version in pubspec.yaml or pass -Force."
    }
}

# The signing key must be the one every installed copy was signed with, or
# in-app updates stop installing (see android/app/build.gradle.kts).
$keystore = if ($env:OUO_KEYSTORE) { $env:OUO_KEYSTORE } else { 'D:\dev\ouoplayer-keys\ouoplayer.keystore' }
if (-not (Test-Path $keystore)) { throw "Signing key not found: $keystore - restore it from your backup before releasing." }

Write-Host "== Building OuOPlayer $full ($(if ($Windows) { 'Android + Windows' } else { 'Android' }))" -ForegroundColor Cyan
Push-Location $buildRoot
try {
    flutter build apk --release --split-per-abi
    if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    if ($Windows) {
        flutter build windows --release
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    }
} finally {
    Pop-Location
}

Write-Host "== Copying Android APKs to $apkDir" -ForegroundColor Cyan
if (Test-Path $apkDir) { Remove-Item -Recurse -Force $apkDir }
New-Item -ItemType Directory -Force $apkDir | Out-Null
foreach ($abi in 'arm64-v8a', 'armeabi-v7a', 'x86_64') {
    Copy-Item (Join-Path $buildRoot "build\app\outputs\flutter-apk\app-$abi-release.apk") `
        (Join-Path $apkDir "OuOPlayer-$version-$abi.apk")
}

if ($Windows) {
    Write-Host "== Copying Windows build to $winDir" -ForegroundColor Cyan
    if (Test-Path $winDir) { Remove-Item -Recurse -Force $winDir }
    New-Item -ItemType Directory -Force $winDir | Out-Null
    $winApp = Join-Path $winDir 'OuOPlayer'
    Copy-Item -Recurse (Join-Path $buildRoot 'build\windows\x64\runner\Release') $winApp
    Compress-Archive -Path "$winApp\*" -DestinationPath (Join-Path $winDir "OuOPlayer-$version-windows-x64.zip")
}

Write-Host "== Done: OuOPlayer $tag" -ForegroundColor Green
Get-ChildItem $targets | Select-Object FullName, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
