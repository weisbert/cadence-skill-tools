#requires -Version 4.0
<#
.SYNOPSIS
  Pack skill_tools (committed HEAD) into a git-free tarball for the red zone.

.DESCRIPTION
  Runs on the YELLOW zone (Windows), after `git pull`. Uses `git archive`, so
  the package is built from committed blobs in the object store, NOT from the
  Windows working tree:
    * paths are always POSIX "/", never "\"
    * text is LF (the repo stores LF; the yellow zone's autocrlf checkout
      cannot corrupt the package)
    * no .git/, no .gitattributes/.gitignore, no pack.ps1, no PLAN.md
      (all export-ignored in .gitattributes)
  Emits  <OutDir>\skill_tools_<shorthash>.tar.gz  plus a matching .sha256
  sidecar in `sha256sum -c` format (LF, no BOM) for deploy.sh to verify.

  Requires only git + PowerShell (Get-FileHash). No Python, no external tar.

.PARAMETER Ref
  Git ref to package (default HEAD).

.PARAMETER OutDir
  Output directory (default: <script dir>\dist).

.EXAMPLE
  powershell -ExecutionPolicy Bypass -File deploy\pack.ps1
#>
param(
    [string]$Ref    = 'HEAD',
    [string]$OutDir = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'

# Repo root = parent of this script's dir (script lives at skill_tools\deploy\).
$RepoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $RepoRoot

# --- sanity ------------------------------------------------------------------
& git rev-parse --is-inside-work-tree 1>$null 2>$null
if ($LASTEXITCODE -ne 0) { throw "Not a git work tree: $RepoRoot" }
if (-not (Test-Path (Join-Path $RepoRoot 'skill_tools.il'))) {
    throw "skill_tools.il not found in $RepoRoot - run this from the skill_tools repo."
}

$dirty = & git status --porcelain
if ($dirty) {
    Write-Warning "Working tree has uncommitted changes; they will NOT be packaged (git archive ships committed $Ref only). Commit + push them first."
}

$short = (& git rev-parse --short $Ref).Trim()
if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrEmpty($short)) { throw "cannot resolve ref: $Ref" }

# --- pack --------------------------------------------------------------------
if (-not (Test-Path $OutDir)) { New-Item -ItemType Directory -Path $OutDir | Out-Null }
$tarName = "skill_tools_$short.tar.gz"
$tarPath = Join-Path $OutDir $tarName

Write-Host ">> packaging $Ref ($short) -> $tarPath"
& git archive --format=tar.gz --prefix=skill_tools/ -o $tarPath $Ref
if ($LASTEXITCODE -ne 0) { throw "git archive failed" }

# --- sha256 sidecar: "<hash>  <name>\n", LF + no BOM (GNU sha256sum -c format)-
$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath $tarPath).Hash.ToLower()
$shaPath = "$tarPath.sha256"
[System.IO.File]::WriteAllText($shaPath, "$hash  $tarName`n", (New-Object System.Text.UTF8Encoding($false)))

# --- report ------------------------------------------------------------------
$size = '{0:N1} KB' -f ((Get-Item $tarPath).Length / 1KB)
Write-Host ""
Write-Host "OK  package : $tarPath  ($size)"
Write-Host "    sha256  : $hash"
Write-Host "    sidecar : $shaPath"
Write-Host ""
Write-Host "commit info:"
& git --no-pager show -s --format='    %h  %cI  %s' $Ref
Write-Host ""
Write-Host "NEXT:"
Write-Host "  1) upload BOTH files to the red zone, into  .../workarea/skill_tools/ :"
Write-Host "       $tarName"
Write-Host "       $tarName.sha256"
Write-Host "  2) on the red zone (login shell is often tcsh -- use bash):"
Write-Host "       cd .../workarea/skill_tools"
Write-Host "       bash deploy/deploy.sh $tarName"
