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
  powershell -ExecutionPolicy Bypass -File scripts\release.ps1 -WindowsOnly

  -WindowsOnly builds just the Windows app (e.g. for a version whose APKs
  are already out).
  -WindowsVersion 0.5.0 numbers the Windows build on its own (Windows isn't
  an official release yet); the APKs keep pubspec.yaml's version.
#>
param([switch]$Windows, [switch]$WindowsOnly, [string]$WindowsVersion, [switch]$Force)
if ($WindowsOnly) { $Windows = $true }
$Android = -not $WindowsOnly

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
$build = ($full -split '\+')[1]
$winVersion = if ($WindowsVersion) { $WindowsVersion } else { $version }

$apkDir = Join-Path $project "release\android\$tag"
$winDir = Join-Path $project "release\windows\v$winVersion"
$targets = @()
if ($Android) { $targets += $apkDir }
if ($Windows) { $targets += $winDir }
foreach ($d in $targets) {
    if ((Test-Path $d) -and -not $Force) {
        throw "$d already exists. Bump the version in pubspec.yaml or pass -Force."
    }
}

# The signing key must be the one every installed copy was signed with, or
# in-app updates stop installing (see android/app/build.gradle.kts).
$keystore = if ($env:OUO_KEYSTORE) { $env:OUO_KEYSTORE } else { 'D:\dev\ouoplayer-keys\ouoplayer.keystore' }
if ($Android -and -not (Test-Path $keystore)) { throw "Signing key not found: $keystore - restore it from your backup before releasing." }

Write-Host "== Building OuOPlayer $full ($((@(if ($Android) { 'Android' }) + @(if ($Windows) { 'Windows' })) -join ' + '))" -ForegroundColor Cyan
Push-Location $buildRoot
try {
    if ($Android) {
        flutter build apk --release --split-per-abi --dart-define=OUO_VERSION=$version
        if ($LASTEXITCODE -ne 0) { throw 'Android build failed' }
    }
    if ($Windows) {
        # media_kit's own libmpv builds leave out most audio filters (no
        # dynaudnorm, volume, alimiter, aresample), so the app's sound chain
        # can't be built with them; the full shinchiro build replaces it.
        $mpvName = 'mpv-dev-x86_64-20261021-git-e471496c56.7z'
        $mpvSha = 'efc719eff3dc5954b4a5efc800632808bcec01cc9034940dd14e5eb7fe9ea633'
        $mpvRoot = 'D:\dev\mpv-full'
        $mpvArchive = Join-Path $mpvRoot $mpvName
        $mpvDll = Join-Path $mpvRoot 'x\libmpv-2.dll'
        if (-not (Test-Path $mpvArchive)) {
            New-Item -ItemType Directory -Force $mpvRoot | Out-Null
            gh release download 20261021 -R shinchiro/mpv-winbuild-cmake -p $mpvName -D $mpvRoot
            if ($LASTEXITCODE -ne 0) { throw 'libmpv download failed' }
        }
        if ((Get-FileHash $mpvArchive -Algorithm SHA256).Hash -ne $mpvSha) { throw "$mpvArchive doesn't match its SHA-256" }
        if (-not (Test-Path $mpvDll)) {
            New-Item -ItemType Directory -Force (Split-Path $mpvDll) | Out-Null
            Push-Location (Split-Path $mpvDll)
            $cmake = (Get-Command cmake -ErrorAction SilentlyContinue).Source
            if (-not $cmake) { $cmake = 'C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe' }
            & $cmake -E tar xf $mpvArchive
            Pop-Location
            if (-not (Test-Path $mpvDll)) { throw 'libmpv extraction failed' }
        }
        # A libmpv folder left from another media_kit libs package is never
        # extracted again; drop it so the build doesn't pick up a stale copy.
        $staleMpv = Join-Path $buildRoot 'build\windows\x64\libmpv'
        if (Test-Path $staleMpv) { Remove-Item -Recurse -Force $staleMpv }

        flutter build windows --release --build-name=$winVersion --build-number=$build --dart-define=OUO_VERSION=$winVersion
        if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
        Copy-Item -Force $mpvDll (Join-Path $buildRoot 'build\windows\x64\runner\Release\libmpv-2.dll')
    }
} finally {
    Pop-Location
}

if ($Android) {
    Write-Host "== Copying Android APKs to $apkDir" -ForegroundColor Cyan
    if (Test-Path $apkDir) { Remove-Item -Recurse -Force $apkDir }
    New-Item -ItemType Directory -Force $apkDir | Out-Null
    foreach ($abi in 'arm64-v8a', 'armeabi-v7a', 'x86_64') {
        Copy-Item (Join-Path $buildRoot "build\app\outputs\flutter-apk\app-$abi-release.apk") `
            (Join-Path $apkDir "OuOPlayer-$version-$abi.apk")
    }
}

if ($Windows) {
    Write-Host "== Copying Windows build to $winDir" -ForegroundColor Cyan
    if (Test-Path $winDir) { Remove-Item -Recurse -Force $winDir }
    New-Item -ItemType Directory -Force $winDir | Out-Null
    $winApp = Join-Path $winDir 'OuOPlayer'
    Copy-Item -Recurse (Join-Path $buildRoot 'build\windows\x64\runner\Release') $winApp
    Compress-Archive -Path "$winApp\*" -DestinationPath (Join-Path $winDir "OuOPlayer-$winVersion-windows-x64.zip")
}

Write-Host "== Done: OuOPlayer $tag" -ForegroundColor Green
Get-ChildItem $targets | Select-Object FullName, @{n = 'MB'; e = { [math]::Round($_.Length / 1MB, 1) } }
