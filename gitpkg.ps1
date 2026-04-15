<#
gitpkg.ps1 - git-backed package manager

Repos root:    ~/gitpkgs
Manifest:      ~/.config/gitpkg/manifest.json

Commands:
  add     <spec>           Clone a repo  (or: gitpkg <spec>)
  update  [spec|all]       Check for updates (no arg), or update "user/repo" / all
  rm  <spec> [-keep]       Remove a repo, optionally keeping files on disk
  get                      List cloned repos
  export  [path]           Export repo list to JSON (or stdout)
  import  <path>           Clone all repos from an export file
  help

Specs accepted:
  user/repo                     => github.com:user/repo
  host:user/repo                => host:user/repo
  https://host/user/repo(.git)
  git@host:user/repo(.git)
#>

[CmdletBinding()]
param(
  [Parameter(Position=0)]
  [string]$Command,

  [Parameter(Position=1)]
  [string]$Arg1,

  [switch]$KeepFiles,
  [switch]$Quiet
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Info([string]$msg) { if (-not $Quiet) { Write-Host $msg } }
function Write-Warn([string]$msg) { Write-Warning $msg }
function Write-Err([string]$msg)  { Write-Host $msg -ForegroundColor Red }

function Assert-GitAvailable {
  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "git was not found in PATH. Install Git and try again."
  }
}

function Invoke-Git {
  param(
    [string[]]$GitArgs,
    [string]$WorkingDir = $null
  )
  $psi = [System.Diagnostics.ProcessStartInfo]::new()
  $psi.FileName               = 'git'
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.UseShellExecute        = $false
  $psi.CreateNoWindow         = $true
  if ($WorkingDir) { $psi.WorkingDirectory = $WorkingDir }
  foreach ($a in $GitArgs) { [void]$psi.ArgumentList.Add($a) }

  $proc = [System.Diagnostics.Process]::new()
  $proc.StartInfo = $psi
  [void]$proc.Start()
  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($proc.ExitCode -ne 0) {
    throw "git $($GitArgs -join ' ') failed (exit $($proc.ExitCode)).`n$($stderr.Trim())"
  }
  [PSCustomObject]@{ Stdout = $stdout; Stderr = $stderr }
}

function Test-GitRepo([string]$Dir) {
  Test-Path -LiteralPath (Join-Path $Dir '.git')
}

function Get-RepoRoot {
  if ([string]::IsNullOrWhiteSpace($HOME)) { throw 'HOME is not set.' }
  Join-Path $HOME 'gitpkgs'
}

function Get-ConfigRoot {
  if ([string]::IsNullOrWhiteSpace($HOME)) { throw 'HOME is not set.' }
  Join-Path $HOME '.config\gitpkg'
}

function Get-ManifestPath { Join-Path (Get-ConfigRoot) 'manifest.json' }

function Get-PackageDir([string]$RepoRoot, [string]$DirName) { Join-Path $RepoRoot $DirName }

function Assert-PathUnderRoot([string]$Path, [string]$Root, [string]$Context) {
  $fullPath = [System.IO.Path]::GetFullPath($Path)
  $fullRoot = [System.IO.Path]::GetFullPath($Root)
  $sep = [System.IO.Path]::DirectorySeparatorChar
  if (-not $fullRoot.EndsWith($sep)) { $fullRoot = "$fullRoot$sep" }

  if (-not $fullPath.StartsWith($fullRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw "Refusing to operate on $Context outside repo root: $fullPath"
  }
}

function Ensure-Dir([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path)) { New-Item -ItemType Directory -Path $Path | Out-Null }
}

function Format-SafeFsName([string]$s) {
  $clean = ($s -replace '[^\w\.\-]+', '_').Trim('_')
  if ([string]::IsNullOrWhiteSpace($clean)) { throw "Cannot derive a valid directory name from '$s'." }
  $clean
}

function Get-DirName([string]$Id) {
  Format-SafeFsName ($Id.Replace(':', '__').Replace('/', '__'))
}

function Format-PathPart([string]$p) {
  $t = $p.Trim().TrimStart('/').TrimEnd('/')
  if ($t.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) { $t = $t.Substring(0, $t.Length - 4) }
  $t
}

function ConvertTo-PackageSpec([string]$Spec) {
  if ([string]::IsNullOrWhiteSpace($Spec)) { throw 'Missing repo spec.' }
  $s = $Spec.Trim()

  if ($s -match '^(?<host>[^:\s]+):(?<path>[^/\s]+/[^/\s]+)$') {
    $rh = $Matches.host; $path = Format-PathPart $Matches.path
    return [PSCustomObject]@{ Id="${rh}:$path"; Url="https://$rh/$path.git"; Host=$rh; Path=$path; Display=$path }
  }

  if ($s -match '^(?<user>[^/\s@:]+)/(?<repo>[^/\s]+)$') {
    $rh = 'github.com'; $path = Format-PathPart $s
    return [PSCustomObject]@{ Id="${rh}:$path"; Url="https://$rh/$path.git"; Host=$rh; Path=$path; Display=$path }
  }

  if ($s -match '^https?://') {
    try {
      $u = [Uri]$s; $rh = $u.Host; $path = Format-PathPart $u.AbsolutePath
      if ($path -notmatch '^[^/]+/[^/]+$') { throw "URL path must be owner/repo (got '$path')." }
      $url = if (-not $s.EndsWith('.git', [System.StringComparison]::OrdinalIgnoreCase)) { "https://$rh/$path.git" } else { $s }
      return [PSCustomObject]@{ Id="${rh}:$path"; Url=$url; Host=$rh; Path=$path; Display=$path }
    } catch [System.UriFormatException] { throw "Malformed URL: $s" }
  }

  if ($s -match '^(?<user>[^@\s]+)@(?<host>[^:\s]+):(?<path>[^/\s]+/[^/\s]+?)(\.git)?$') {
    $rh = $Matches.host; $path = Format-PathPart $Matches.path
    return [PSCustomObject]@{ Id="${rh}:$path"; Url=$s; Host=$rh; Path=$path; Display=$path }
  }

  throw "Unrecognised spec '$Spec'. Use: user/repo | host:user/repo | https://... | git@host:..."
}

function New-EmptyManifest {
  [PSCustomObject]@{
    version = 1; packages = [PSCustomObject]@{}
    createdAt = (Get-Date -Format 'o'); updatedAt = (Get-Date -Format 'o')
  }
}

function Import-Manifest {
  Ensure-Dir (Get-ConfigRoot)
  $path = Get-ManifestPath
  if (-not (Test-Path -LiteralPath $path)) { return New-EmptyManifest }
  $raw = Get-Content -LiteralPath $path -Raw
  if ([string]::IsNullOrWhiteSpace($raw)) { return New-EmptyManifest }
  try {
    $obj = $raw | ConvertFrom-Json -Depth 64
  } catch {
    throw "Invalid manifest JSON at '$path'. Fix the file or remove it to regenerate. $($_.Exception.Message)"
  }
  if (-not $obj.PSObject.Properties['packages'])  { $obj | Add-Member -NotePropertyName packages  -NotePropertyValue ([PSCustomObject]@{}) -Force }
  if (-not $obj.PSObject.Properties['version'])   { $obj | Add-Member -NotePropertyName version   -NotePropertyValue 1 -Force }
  if (-not $obj.PSObject.Properties['createdAt']) { $obj | Add-Member -NotePropertyName createdAt -NotePropertyValue (Get-Date -Format 'o') -Force }
  if (-not $obj.PSObject.Properties['updatedAt']) { $obj | Add-Member -NotePropertyName updatedAt -NotePropertyValue (Get-Date -Format 'o') -Force }
  $obj
}

function Export-Manifest([object]$Manifest) {
  $Manifest.updatedAt = (Get-Date -Format 'o')
  $path = Get-ManifestPath; $tmp = "$path.tmp"
  ($Manifest | ConvertTo-Json -Depth 64) | Set-Content -LiteralPath $tmp -Encoding UTF8
  Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Get-PackageIds([object]$Manifest) {
  $list = [System.Collections.Generic.List[string]]::new()
  foreach ($prop in $Manifest.packages.PSObject.Properties) { $list.Add($prop.Name) }
  $list.Sort()
  Write-Output -NoEnumerate ([string[]]$list)
}

function Get-PackageEntry([object]$Manifest, [string]$Id) {
  $Manifest.packages.PSObject.Properties[$Id]?.Value
}

function Show-Help {
  @"
gitpkg - git-backed package manager (PowerShell)

Roots:
  Repos:     ~/gitpkgs
  Manifest:  ~/.config/gitpkg/manifest.json

Commands:
  Add     <spec>           Install (clone) a repo package  (or: gitpkg <spec>)
  Update  [spec|all]       No arg: show update status table
                           spec:   update one package
                           all:    update all packages
  Remove  <spec>           Uninstall a package
          [-KeepFiles]     Remove from manifest only, keep files on disk
  Get                      List installed packages
  Export  [path]           Export package list to JSON (stdout if no path)
  Import  <path>           Install all packages from an export file
  Help                     Show this help

Specs:
  user/repo
  host:user/repo
  https://host/user/repo(.git)
  git@host:user/repo(.git)

Examples:
  .\gitpkg.ps1 BurntSushi/ripgrep
  .\gitpkg.ps1 Add    BurntSushi/ripgrep
  .\gitpkg.ps1 Update
  .\gitpkg.ps1 Update all
  .\gitpkg.ps1 Update BurntSushi/ripgrep
  .\gitpkg.ps1 Remove BurntSushi/ripgrep
  .\gitpkg.ps1 Get
  .\gitpkg.ps1 Export .\gitpkg.json
  .\gitpkg.ps1 Import .\gitpkg.json
"@ | Write-Host
}

function Get-GitpkgPackage {
  $m = Import-Manifest; $ids = Get-PackageIds $m
  if ($ids.Count -eq 0) { Write-Info 'No packages installed.'; return }
  $repoRoot = Get-RepoRoot
  $rows = foreach ($id in $ids) {
    $p   = Get-PackageEntry $m $id
    $dir = Get-PackageDir -RepoRoot $repoRoot -DirName $p.dir
    [PSCustomObject]@{
      Package = if ($p.display) { $p.display } else { $id }
      Status  = (Test-Path -LiteralPath $dir) ? 'ok' : 'missing'
      URL     = $p.url
    }
  }
  $rows | Format-Table -AutoSize
}

function Add-GitpkgPackage([string]$Spec, [object]$Manifest = $null, [switch]$SkipSave) {
  if ([string]::IsNullOrWhiteSpace($Spec)) { throw 'Add requires a repo spec.' }
  $repoRoot = Get-RepoRoot; Ensure-Dir $repoRoot
  $m = if ($null -ne $Manifest) { $Manifest } else { Import-Manifest }
  $pkg = ConvertTo-PackageSpec -Spec $Spec; $id = $pkg.Id

  if (Get-PackageEntry $m $id) { Write-Warn "Already installed: $id"; return }

  $dirName = Get-DirName -Id $id
  $dirPath = Get-PackageDir -RepoRoot $repoRoot -DirName $dirName

  if (Test-Path -LiteralPath $dirPath) {
    if (Test-GitRepo -Dir $dirPath) {
      Write-Warn "Directory already exists as a git repo; recording in manifest: $dirPath"
      try {
        $origin = (Invoke-Git -GitArgs @('remote','get-url','origin') -WorkingDir $dirPath).Stdout.Trim()
        if (-not [string]::IsNullOrWhiteSpace($origin)) { $pkg.Url = $origin }
      } catch { }
    } else { throw "Target path exists but is not a git repo: $dirPath" }
  } else {
    Write-Info "Cloning $($pkg.Url) -> $dirPath"
    Invoke-Git -GitArgs @('clone', $pkg.Url, $dirPath) | Out-Null
  }

  $m.packages | Add-Member -NotePropertyName $id -NotePropertyValue ([PSCustomObject]@{
    id = $id; display = $pkg.Display; url = $pkg.Url
    dir = $dirName; installed = (Get-Date -Format 'o')
  }) -Force
  if (-not $SkipSave) { Export-Manifest $m }
  Write-Info "Installed: $id"
}

function Update-OnePackage([string]$Id) {
  $m = Import-Manifest; $p = Get-PackageEntry $m $Id
  if (-not $p) { throw "Package not found in manifest: $Id" }
  $repoRoot = Get-RepoRoot
  Ensure-Dir $repoRoot
  $dir = Get-PackageDir -RepoRoot $repoRoot -DirName $p.dir

  if (-not (Test-Path -LiteralPath $dir)) {
    Write-Warn "Directory missing for '$Id'; re-cloning."
    Invoke-Git -GitArgs @('clone', $p.url, $dir) | Out-Null
    return 'updated'
  }
  if (-not (Test-GitRepo -Dir $dir)) { throw "Not a git repo for '${Id}': $dir" }
  Write-Info "Updating $Id..."
  $before = (Invoke-Git -GitArgs @('rev-parse', 'HEAD') -WorkingDir $dir).Stdout.Trim()
  Invoke-Git -GitArgs @('pull', '--ff-only') -WorkingDir $dir | Out-Null
  $after  = (Invoke-Git -GitArgs @('rev-parse', 'HEAD') -WorkingDir $dir).Stdout.Trim()
  if ($before -ne $after) { 'updated' } else { 'latest' }
}

function Get-PackageUpdateStatus([string]$Id, [object]$Manifest, [string]$RepoRoot) {
  $p = Get-PackageEntry $Manifest $Id
  if (-not $p) { return [PSCustomObject]@{ Package=$Id; Status='not in manifest'; Behind=''; Reason='' } }

  $display = if ($p.display) { $p.display } else { $Id }
  $dir     = Get-PackageDir -RepoRoot $RepoRoot -DirName $p.dir

  if (-not (Test-Path -LiteralPath $dir) -or -not (Test-GitRepo -Dir $dir)) {
    return [PSCustomObject]@{ Package=$display; Status='missing'; Behind=''; Reason='' }
  }
  try {
    Invoke-Git -GitArgs @('fetch', '--quiet') -WorkingDir $dir | Out-Null
    $behind    = (Invoke-Git -GitArgs @('rev-list','--count','HEAD..@{u}') -WorkingDir $dir).Stdout.Trim()
    $available = ($behind -ne '' -and $behind -ne '0')
    [PSCustomObject]@{
      Package = $display
      Status  = if ($available) { 'update available' } else { 'up-to-date' }
      Behind  = if ($available) { "$behind commit$(if ($behind -ne '1') {'s'})" } else { '' }
      Reason  = ''
    }
  } catch {
    $msg = $_.Exception.Message
    $reason = if ($msg -match 'HEAD\.\.@\{u\}|no upstream configured|no upstream branch') {
      'no upstream branch configured'
    } elseif ($msg -match 'Authentication failed|Permission denied|Could not read from remote repository') {
      'authentication/permission failure'
    } else {
      ($msg -split "`r?`n")[0]
    }

    [PSCustomObject]@{ Package=$display; Status='error'; Behind=''; Reason=$reason }
  }
}

function Update-GitpkgPackage([string]$Target) {
  $m = Import-Manifest; $ids = Get-PackageIds $m; $repoRoot = Get-RepoRoot

  if ([string]::IsNullOrWhiteSpace($Target)) {
    if ($ids.Count -eq 0) { Write-Info 'No packages installed.'; return }
    Write-Info 'Checking for updates...'
    $rows = foreach ($id in $ids) { Get-PackageUpdateStatus -Id $id -Manifest $m -RepoRoot $repoRoot }
    $rows | Format-Table -AutoSize
    return
  }

  if ($Target -ieq 'all') {
    if ($ids.Count -eq 0) { Write-Info 'No packages installed.'; return }
    $failCount = 0
    foreach ($id in $ids) {
      try   { Update-OnePackage -Id $id | Out-Null }
      catch { $failCount++; Write-Err "Failed [$id]: $($_.Exception.Message)" }
    }
    if ($failCount -gt 0) { throw "Update finished with $failCount failure(s)." }
    return
  }

  $id = (ConvertTo-PackageSpec -Spec $Target).Id
  $status = Update-OnePackage -Id $id
  if ($status -eq 'updated') { Write-Info "Updated: $id" } else { Write-Info "Already latest: $id" }
}

function Remove-GitpkgPackage([string]$Spec, [switch]$KeepFiles) {
  if ([string]::IsNullOrWhiteSpace($Spec)) { throw 'Remove requires a repo spec.' }
  $id = (ConvertTo-PackageSpec -Spec $Spec).Id
  $m  = Import-Manifest; $p = Get-PackageEntry $m $id
  if (-not $p) { Write-Warn "Not found in manifest: $id"; return }

  $repoRoot = Get-RepoRoot
  $dir = Get-PackageDir -RepoRoot $repoRoot -DirName $p.dir
  Assert-PathUnderRoot -Path $dir -Root $repoRoot -Context "package directory '$id'"
  if ($KeepFiles) {
    Write-Info "Keeping files at $dir (manifest only)."
  } elseif (Test-Path -LiteralPath $dir) {
    Write-Info "Deleting $dir"
    Remove-Item -LiteralPath $dir -Recurse -Force
  }
  $m.packages.PSObject.Properties.Remove($id)
  Export-Manifest $m
  Write-Info "Removed: $id"
}

function Export-GitpkgPackage([string]$OutPath) {
  $m = Import-Manifest; $ids = Get-PackageIds $m
  $doc = [PSCustomObject]@{
    format = 'gitpkg-export'; version = 1; exportedAt = (Get-Date -Format 'o')
    packages = @(foreach ($id in $ids) {
      $p = Get-PackageEntry $m $id
      [PSCustomObject]@{ id=$p.id; url=$p.url; display=$p.display }
    })
  }
  if ([string]::IsNullOrWhiteSpace($OutPath)) { $doc | ConvertTo-Json -Depth 64; return }
  $parent = Split-Path -Parent $OutPath
  if (-not [string]::IsNullOrWhiteSpace($parent)) { Ensure-Dir $parent }
  $doc | ConvertTo-Json -Depth 64 | Set-Content -LiteralPath $OutPath -Encoding UTF8
  Write-Info "Exported $($ids.Count) package(s) to $OutPath"
}

function Import-GitpkgPackage([string]$InPath) {
  if ([string]::IsNullOrWhiteSpace($InPath)) { throw 'Import requires a path to an export JSON file.' }
  if (-not (Test-Path -LiteralPath $InPath)) { throw "File not found: $InPath" }
  try {
    $obj = Get-Content -LiteralPath $InPath -Raw | ConvertFrom-Json -Depth 64
  } catch {
    throw "Invalid import JSON at '$InPath'. Ensure the export file is valid JSON. $($_.Exception.Message)"
  }
  if (-not $obj.PSObject.Properties['packages']) { throw "Invalid export file: missing 'packages' field." }

  $m = Import-Manifest
  $installed = 0; $skipped = 0; $failed = 0
  foreach ($entry in $obj.packages) {
    try {
      if ([string]::IsNullOrWhiteSpace($entry.url)) { throw "Entry is missing 'url'." }
      $id = (ConvertTo-PackageSpec -Spec $entry.url).Id
      if (Get-PackageEntry $m $id) { $skipped++; continue }
      Add-GitpkgPackage -Spec $entry.url -Manifest $m -SkipSave
      $installed++
    } catch {
      $failed++
      Write-Err "Import failed [$($entry.url)]: $($_.Exception.Message)"
    }
  }

  if ($installed -gt 0) { Export-Manifest $m }
  Write-Info "Import complete — installed: $installed  skipped: $skipped  failed: $failed"
  if ($failed -gt 0) { throw 'Import completed with failures.' }
}

# ---------- main ----------

try {
  Assert-GitAvailable
  if ([string]::IsNullOrWhiteSpace($Command)) { Show-Help; exit 0 }

  switch ($Command.ToLowerInvariant()) {
    'help'   { Show-Help }
    'get'    { Get-GitpkgPackage }
    'add'    { Add-GitpkgPackage    -Spec $Arg1 }
    'update' { Update-GitpkgPackage -Target $Arg1 }
    'rm'     { Remove-GitpkgPackage -Spec $Arg1 -KeepFiles:$KeepFiles }
    'export' { Export-GitpkgPackage -OutPath $Arg1 }
    'import' { Import-GitpkgPackage -InPath $Arg1 }
    default  {
      # Treat bare specs (user/repo, host:user/repo, URLs, git@ URLs) as implicit Add
      try   { Add-GitpkgPackage -Spec $Command }
      catch { throw "Unknown command '$Command'. Run '.\gitpkg.ps1 help' for usage." }
    }
  }
} catch {
  Write-Err $_.Exception.Message
  exit 1
}
