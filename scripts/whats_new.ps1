<#
.SYNOPSIS
  Uploads a version's 新功能 lines to the update server (R2), so the in-app
  新功能 window can change without a new release (v1.21.0).

.DESCRIPTION
  Reads assets\whats_new.txt (or -File) and uploads it as
  whats-new/<version>.json: {"version": "...", "lines": [...]}. The app reads
  it when it shows 新功能 and falls back to the copy built into it.

  The version defaults to the one in pubspec.yaml. publish.ps1 runs this too.

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File scripts\whats_new.ps1
  powershell -ExecutionPolicy Bypass -File scripts\whats_new.ps1 -Version 1.21.0 -File release\notes\whats-new-1.21.0.txt
#>
param([string]$Version, [string]$File)

$ErrorActionPreference = 'Stop'
# Node tools get an ASCII path through the junction.
$root = 'D:\dev\ouoplayer'
$bucket = 'ouoplayer-updates'

if (-not $Version) {
    $Version = ((Select-String -Path (Join-Path $root 'pubspec.yaml') -Pattern '^version:\s*([\d.]+)').Matches[0].Groups[1].Value)
}
if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Not a version: $Version" }
if (-not $File) { $File = Join-Path $root 'assets\whats_new.txt' }
if (-not (Test-Path $File)) { throw "Missing $File" }

$lines = @(Get-Content $File -Encoding UTF8 | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($lines.Count -eq 0) { throw "$File has no lines" }

$tmp = Join-Path ([IO.Path]::GetTempPath()) "ouo-whats-new-$Version.json"
$json = [ordered]@{ version = $Version; lines = $lines } | ConvertTo-Json -Depth 3
[IO.File]::WriteAllText($tmp, $json, [Text.UTF8Encoding]::new($false))

Write-Host "== Uploading whats-new/$Version.json ($($lines.Count) lines)" -ForegroundColor Cyan
& npx.cmd --yes wrangler@4 r2 object put "$bucket/whats-new/$Version.json" --file $tmp --content-type 'application/json; charset=utf-8' --remote
if ($LASTEXITCODE -ne 0) { throw 'wrangler upload failed' }
Write-Host "== Uploaded 新功能 for $Version"
