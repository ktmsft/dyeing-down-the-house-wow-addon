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

<#
  Entry names are written BY HAND, and that is not gold-plating.

  The zip spec says paths are separated by forward slashes. Both of the obvious
  ways to build an archive on Windows PowerShell 5.1 ignore that and write
  BACKSLASHES -- "DyeingDownTheHouse\Core.lua". Compress-Archive does it, and so
  does ZipFile::CreateFromDirectory, which is the fix usually recommended for
  Compress-Archive doing it. Both were tried here; both failed the check below.

  An extractor that takes the name literally produces a single file called
  "DyeingDownTheHouse\Core.lua" instead of a folder with files in it. The WoW client
  and CurseForge have coped on every release so far, so this was never visibly
  breaking anything -- but macOS Archive Utility is the one that bites, and the
  resulting bug report is not "your addon is broken", it is silence from someone
  whose addon never appeared.

  CreateEntry takes the name verbatim, so this is the only way to be sure. The
  single top-level DyeingDownTheHouse/ folder is preserved deliberately: WoW
  requires the .toc filename to match the folder name, so that prefix is load-
  bearing, not cosmetic.
#>
# Two assemblies, not one: ZipFile lives in ...Compression.FileSystem, while
# ZipArchive and ZipArchiveMode live in ...Compression. Loading only the first gets
# you "Unable to find type [System.IO.Compression.ZipArchiveMode]".
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName System.IO.Compression

$stream  = [System.IO.File]::Open($zip, [System.IO.FileMode]::Create)
$archive = New-Object System.IO.Compression.ZipArchive(
    $stream, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($file in (Get-ChildItem -LiteralPath $staging -Recurse -File)) {
        $relative = $file.FullName.Substring($staging.Length).TrimStart('\', '/')
        $name     = "$folder/" + ($relative -replace '\\', '/')

        $entry  = $archive.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Optimal)
        $target = $entry.Open()
        $source = [System.IO.File]::OpenRead($file.FullName)
        try { $source.CopyTo($target) } finally { $source.Dispose(); $target.Dispose() }
    }
} finally {
    $archive.Dispose()
    $stream.Dispose()
}

# Read the names back and fail loudly rather than shipping a bad archive quietly.
$archive = [System.IO.Compression.ZipFile]::OpenRead($zip)
$backslashed = @($archive.Entries | Where-Object { $_.FullName -like '*\*' })
$entryCount = $archive.Entries.Count
$archive.Dispose()
if ($backslashed.Count -gt 0) {
    Remove-Item $zip -Force
    throw "$($backslashed.Count) of $entryCount entries use backslash separators. Archive deleted rather than shipped."
}

$files = Get-ChildItem $staging -Recurse -File
Remove-Item $staging -Recurse -Force

Write-Host ("  {0}  ({1} files, {2:N0} KB)" -f (Split-Path $zip -Leaf), $files.Count, ((Get-Item $zip).Length / 1KB))
$files | ForEach-Object { Write-Host ("    " + $_.Name) }
Write-Host "Top-level folder in the zip is $folder/ (drop into Interface/AddOns)."
