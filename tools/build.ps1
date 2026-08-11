<#
    build.ps1 - package the addon into a distributable zip for CurseForge.

    Produces dist/DyeingDownTheHouse-<version>.zip, whose single top-level folder is
    "DyeingDownTheHouse". WoW makes the .toc filename match the folder name, so that
    folder name is not cosmetic: rename it and the addon stops loading.

    Version comes from the .toc, so the zip name and the addon can never disagree.

    Left out: the dev loader (DyeingDownTheHouseDev.toc), tools/, tests/,
    reference/, .git, dist/, and the two docs that are web pages rather than
    shipped files (README.md is the GitHub page, CURSEFORGE.md the store one).

    The exclude list is a DENY list, so anything new in the repo root ships by
    default. That is the safer way round for source files and the wrong way round
    for notes -- add new non-shipping folders here when you add them.

    Usage:  pwsh tools/build.ps1
#>

$ErrorActionPreference = 'Stop'

$repo   = Split-Path -Parent $PSScriptRoot     # tools/ -> repo root
$folder = 'DyeingDownTheHouse'                 # must match the .toc base name
$dist   = Join-Path $repo 'dist'

$toc     = Get-Content (Join-Path $repo "$folder.toc") -Encoding UTF8
$version = ($toc | Select-String -Pattern '^##\s*Version:\s*(.+?)\s*$').Matches[0].Groups[1].Value
if (-not $version) { throw "Could not read ## Version from $folder.toc" }

$exclude = @('.git', '.gitignore', '.claude', 'dist', 'tools', 'tests', 'reference',
             'README.md', 'CURSEFORGE.md', "${folder}Dev.toc")

Write-Host "Building $folder $version ..."

if (Test-Path $dist) { Remove-Item $dist -Recurse -Force }
New-Item -ItemType Directory -Path $dist | Out-Null

$staging = Join-Path $dist $folder
New-Item -ItemType Directory -Path $staging -Force | Out-Null

Get-ChildItem -LiteralPath $repo -Force |
    Where-Object { $exclude -notcontains $_.Name } |
    ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $staging -Recurse -Force }

$zip = Join-Path $dist "$folder-$version.zip"
Compress-Archive -Path $staging -DestinationPath $zip -Force

$files = Get-ChildItem $staging -Recurse -File
Remove-Item $staging -Recurse -Force

Write-Host ("  {0}  ({1} files, {2:N0} KB)" -f (Split-Path $zip -Leaf), $files.Count, ((Get-Item $zip).Length / 1KB))
$files | ForEach-Object { Write-Host ("    " + $_.Name) }
Write-Host "Top-level folder in the zip is $folder/ (drop into Interface/AddOns)."
