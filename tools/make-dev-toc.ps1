<#
  make-dev-toc.ps1 - regenerate the gitignored dev loader from the shipped .toc.

  This dev checkout lives in a codename folder "<Name>Dev" so a live CurseForge "<Name>"
  install can sit beside it. WoW needs the .toc name to match the folder, so the folder needs
  <Name>Dev.toc: the shipped <Name>.toc with a "[DEV]" Title and Dev-suffixed SavedVariables
  (Core switches to them when the Title has "[DEV]"). Only ONE copy enabled at a time.
  Run after editing the shipped .toc:  pwsh tools/make-dev-toc.ps1

  It also stamps ## Interface with the version of the CLIENT this checkout is sitting
  in, read from the installation's own .build.info. See the note above Get-ClientToc.

  RUN IT AFTER EVERY DEPLOY, not just after editing the .toc. The dev loader is
  gitignored, so pulling or resetting a checkout never updates it - and a file added
  since it was last generated silently never loads. Two files sat "deployed" for
  hours that way, with nothing on screen to say the addon was ignoring them.
#>
$ErrorActionPreference = 'Stop'
$repo     = Split-Path -Parent $PSScriptRoot
$codename = Split-Path -Leaf $repo
$shipToc  = ($codename -replace 'Dev$','') + '.toc'

<#
  The interface version of the client this folder lives in.

  The shipped .toc names the version we BUILD for, which is the right answer for the
  zip and the wrong one for a dev loader: a checkout targeting 12.1 will not load on a
  12.0.7 client at all, and the failure is silent - no addon, no slash command, no
  error, just a greyed line in a list you have to think to go and look at. That cost a
  round of "/dye does nothing" that had nothing to do with the addon.

  So the dev loader declares whatever client it is sitting in, and testing a
  next-patch build against an older client needs no "Load out of date AddOns" dance.
  Behaviour is unaffected: the addon reads the real client version from GetBuildInfo,
  not from its own .toc, so a version guard still fires exactly as it would in a
  shipped build.

  Falls back to the shipped value if anything cannot be read. A dev loader that
  declares the wrong version is a nuisance; one this script refused to write is worse.
#>
function Get-ClientToc {
    param($RepoPath)

    # Walk up to the _retail_ / _ptr_ / _beta_ folder, and past it to the install root.
    $dir = Get-Item -LiteralPath $RepoPath
    while ($dir -ne $null -and $dir.Name -notmatch '^_.+_$') { $dir = $dir.Parent }
    if ($dir -eq $null) { return $null }
    $flavor = $dir.Name
    $root   = $dir.Parent
    if ($root -eq $null) { return $null }

    $buildInfo = Join-Path $root.FullName '.build.info'
    if (-not (Test-Path -LiteralPath $buildInfo)) { return $null }

    # Which product row belongs to this flavour.
    $product = $null
    switch ($flavor) {
        '_retail_'      { $product = 'wow' }
        '_ptr_'         { $product = 'wowt' }
        '_xptr_'        { $product = 'wowxptr' }
        '_beta_'        { $product = 'wow_beta' }
        '_classic_'     { $product = 'wow_classic' }
        '_classic_era_' { $product = 'wow_classic_era' }
    }
    if ($product -eq $null) { return $null }

    # .build.info is a pipe-delimited table with a header row naming the columns.
    $lines = Get-Content -LiteralPath $buildInfo -Encoding UTF8
    if ($lines.Count -lt 2) { return $null }
    $headers = $lines[0].Split('|')
    $iVersion = -1
    $iProduct = -1
    for ($i = 0; $i -lt $headers.Count; $i++) {
        if ($headers[$i] -like 'Version!*') { $iVersion = $i }
        if ($headers[$i] -like 'Product!*') { $iProduct = $i }
    }
    if ($iVersion -lt 0 -or $iProduct -lt 0) { return $null }

    foreach ($line in $lines[1..($lines.Count - 1)]) {
        $cols = $line.Split('|')
        if ($cols.Count -gt [Math]::Max($iVersion, $iProduct) -and $cols[$iProduct] -eq $product) {
            # "12.0.7.68974" -> 120007. Major*10000 + minor*100 + patch, which is how
            # Blizzard numbers ## Interface.
            $parts = $cols[$iVersion].Split('.')
            if ($parts.Count -ge 3) {
                return ([int]$parts[0] * 10000) + ([int]$parts[1] * 100) + [int]$parts[2]
            }
        }
    }
    return $null
}

$clientToc = $null
try { $clientToc = Get-ClientToc -RepoPath $repo } catch { $clientToc = $null }

# Encoding is explicit on both ends. Windows PowerShell reads as ANSI and writes a
# BOM by default, which mangles the em dash in the Notes line and hands WoW a .toc
# that doesn't match the shipped one byte for byte. pwsh defaults are already right;
# being explicit makes the script produce the same file under either.
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$out = Get-Content (Join-Path $repo $shipToc) -Encoding UTF8 | ForEach-Object {
    $line = $_ -replace '^(## Title: .+?)\s*$', '${1} [DEV]' `
               -replace '^(## SavedVariables(?:PerCharacter)?: )(\w+?)DB\s*$', '${1}${2}DevDB'
    if ($clientToc -ne $null) {
        $line = $line -replace '^## Interface:\s*\d+\s*$', ("## Interface: " + $clientToc)
    }
    $line
}
[System.IO.File]::WriteAllLines((Join-Path $repo ($codename + '.toc')), $out, $utf8NoBom)

$note = "[DEV] title + Dev saved variables"
if ($clientToc -ne $null) { $note = $note + ", Interface " + $clientToc + " (this client)" }
else { $note = $note + ", Interface unchanged (client version unreadable)" }
Write-Host ("Wrote " + $codename + ".toc  (dev loader: " + $note + ")")
