param(
  [string]$MainRef = "origin/main"
)

$ErrorActionPreference = "Stop"

$repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
Set-Location $repoRoot

$basePath = Join-Path $repoRoot "version.base.json"
$outPath = Join-Path $repoRoot "version.json"

if (-not (Test-Path $basePath)) {
  throw "Missing version.base.json"
}

$base = Get-Content $basePath -Raw | ConvertFrom-Json
$major = [int]$base.major
$minor = [int]$base.minor

$hasMainRef = $false
try {
  git rev-parse --verify $MainRef *> $null
  $hasMainRef = $true
} catch {
  $hasMainRef = $false
}

if ($hasMainRef) {
  $patch = [int](git rev-list --count "$MainRef..HEAD")
} else {
  $patch = [int](git rev-list --count HEAD)
}

$build = [int](git rev-list --count HEAD)
$commit = (git rev-parse --short HEAD).Trim()
$version = "$major.$minor.$patch"
$updatedAtUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

$payload = [ordered]@{
  version = $version
  build = $build
  commit = $commit
  updatedAtUtc = $updatedAtUtc
}

$json = $payload | ConvertTo-Json
[System.IO.File]::WriteAllText($outPath, $json + [Environment]::NewLine, [System.Text.Encoding]::UTF8)

Write-Output "Updated version.json -> $version+build.$build ($commit)"
