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
$out = Get-Content (Join-Path $repo $shipToc) | ForEach-Object {
    $_ -replace '^(## Title: .+?)\s*$', '${1} [DEV]' `
       -replace '^(## SavedVariables(?:PerCharacter)?: )(\w+?)DB\s*$', '${1}${2}DevDB'
}
Set-Content -Path (Join-Path $repo ($codename + '.toc')) -Value $out -Encoding utf8
Write-Host ("Wrote " + $codename + ".toc  (dev loader: [DEV] title + Dev saved variables)")
