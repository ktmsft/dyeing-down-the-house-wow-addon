<#
  make-dev-toc.ps1 - regenerate the gitignored dev loader from the shipped .toc.

  This dev checkout lives in a codename folder "<Name>Dev" so a live CurseForge "<Name>"
  install can sit beside it. WoW needs the .toc name to match the folder, so the folder needs
  <Name>Dev.toc: the shipped <Name>.toc with a "[DEV]" Title and Dev-suffixed SavedVariables
  (Core switches to them when the Title has "[DEV]"). Only ONE copy enabled at a time.
  Run after editing the shipped .toc:  pwsh tools/make-dev-toc.ps1
#>
$ErrorActionPreference = 'Stop'
$repo     = Split-Path -Parent $PSScriptRoot
$codename = Split-Path -Leaf $repo
$shipToc  = ($codename -replace 'Dev$','') + '.toc'
# Encoding is explicit on both ends. Windows PowerShell reads as ANSI and writes a
# BOM by default, which mangles the em dash in the Notes line and hands WoW a .toc
# that doesn't match the shipped one byte for byte. pwsh defaults are already right;
# being explicit makes the script produce the same file under either.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$out = Get-Content (Join-Path $repo $shipToc) -Encoding UTF8 | ForEach-Object {
    $_ -replace '^(## Title: .+?)\s*$', '${1} [DEV]' `
       -replace '^(## SavedVariables(?:PerCharacter)?: )(\w+?)DB\s*$', '${1}${2}DevDB'
}
[System.IO.File]::WriteAllLines((Join-Path $repo ($codename + '.toc')), $out, $utf8NoBom)
Write-Host ("Wrote " + $codename + ".toc  (dev loader: [DEV] title + Dev saved variables)")
