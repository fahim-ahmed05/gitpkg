param(
    [Parameter(Mandatory=$true, Position=0)]
    [ValidateSet('clone', 'pull', 'list', 'rm', 'export', 'import')]
    [string]$Command,

    [Parameter(Position=1)]
    [string]$Target,

    [Parameter(Position=2)]
    [string]$Branch, 

    [string]$Name
)

if (-not (Get-Command "git" -ErrorAction SilentlyContinue)) {
    Write-Host "Error: 'git' command not found. Please install Git and ensure it is in your system PATH." -ForegroundColor Red
    exit 1
}

$ConfigDir = Join-Path $env:USERPROFILE ".config\gitpkg"
$ConfigFile = Join-Path $ConfigDir "repos.json"
$InstallDir = Join-Path $env:USERPROFILE "gitpkg"

if (-not (Test-Path $ConfigDir)) { New-Item -ItemType Directory -Path $ConfigDir | Out-Null }
if (-not (Test-Path $InstallDir)) { New-Item -ItemType Directory -Path $InstallDir | Out-Null }
if (-not (Test-Path $ConfigFile)) { Set-Content -Path $ConfigFile -Value "[]" }

function Get-Packages {
    $content = Get-Content $ConfigFile -Raw
    if ([string]::IsNullOrWhiteSpace($content) -or $content -eq '[]') { return @() }
    return @($content | ConvertFrom-Json)
}

function Save-Packages {
    param([array]$Packages)
    if ($Packages.Count -eq 0) {
        Set-Content -Path $ConfigFile -Value "[]"
    } else {
        $Packages | ConvertTo-Json -Depth 2 | Set-Content -Path $ConfigFile
    }
}

function Get-ShortHash {
    param([string]$InputString)
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($InputString)
    $hash = [System.Security.Cryptography.MD5]::Create().ComputeHash($bytes)
    $hex = [System.BitConverter]::ToString($hash) -replace '-'
    return $hex.Substring(0, 8).ToLower()
}

function Get-RemoteDefaultBranch {
    param([string]$Url)
    try {
        $output = & git ls-remote --symref $Url HEAD 2>$null
        $outputString = $output -join "`n"
        if ($outputString -match 'ref: refs/heads/([^\s]+)\s+HEAD') { return $matches[1] }
    } catch {}
    return "master" 
}

switch ($Command) {
    'clone' {
        if (-not $Target) { 
            Write-Host "Error: URL required for clone. Usage: gitpkg clone <url>" -ForegroundColor Red
            exit 1 
        }
        
        if (-not $Name) { 
            $Name = ($Target -split '[:/]')[-1] -replace '\.git$','' 
        }

        if ([string]::IsNullOrWhiteSpace($Branch)) {
            Write-Host "Detecting default branch for $Name..." -ForegroundColor DarkGray
            $Branch = Get-RemoteDefaultBranch -Url $Target
            Write-Host "Detected default branch: " -NoNewline; Write-Host $Branch -ForegroundColor Yellow
        }

        if ($Target -match '^(?:https?://|ssh://)?(?:git@)?([^/:]+)[/:](.+?)(?:\.git)?$') {
            $Domain = $matches[1]
            $RepoPath = $matches[2]
        } else {
            Write-Host "Error: Could not parse URL properly. Ensure it is a valid Git or SSH URL." -ForegroundColor Red
            exit 1
        }

        $FormattedId = "{0}:{1}@{2}" -f $Domain, $RepoPath, $Branch
        $ShortHash = Get-ShortHash -InputString $FormattedId
        $DirName = "{0}@{1}-{2}" -f $Name, $Branch, $ShortHash
        
        [array]$Packages = Get-Packages
        if ($Packages.Id -contains $FormattedId) { 
            Write-Host "Repository '$FormattedId' is already cloned and tracked." -ForegroundColor Yellow
            exit 0 
        }

        $TargetPath = Join-Path $InstallDir $DirName

        if (Test-Path $TargetPath) {
            Write-Host "Error: The directory '$DirName' already exists on disk but is not tracked." -ForegroundColor Red
            Write-Host "Clean it up by running: Remove-Item -Recurse -Force `"$TargetPath`"" -ForegroundColor Yellow
            exit 1
        }

        $gitArgs = @("clone", "--depth", "1", $Target, $TargetPath, "--branch", $Branch)

        Write-Host "==> Cloning $FormattedId..." -ForegroundColor Cyan
        & git @gitArgs

        if ($LASTEXITCODE -eq 0) {
            $newPkg = [PSCustomObject]@{
                Id = $FormattedId
                Name = $Name
                Hash = $ShortHash
                Url = $Target
                Branch = $Branch
                Path = $TargetPath
            }
            $Packages += $newPkg
            Save-Packages $Packages
            Write-Host "Successfully cloned to '$DirName'." -ForegroundColor Green
        } else {
            Write-Host "Failed to clone '$Name'. Please check your network or SSH keys." -ForegroundColor Red
        }
    }

    'pull' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -eq 0) {
            Write-Host "No repositories tracked." -ForegroundColor Yellow
            exit 0
        }

        if (-not $Target) {
            Write-Host "Fetching origin data for all repositories to check status..." -ForegroundColor Cyan
            $StatusList = @()

            foreach ($pkg in $Packages) {
                if (Test-Path $pkg.Path) {
                    Push-Location $pkg.Path
                    & git fetch --quiet 2>$null
                    
                    $behindCount = 0
                    $isBehind = $false
                    try {
                        $output = & git rev-list --count HEAD..@{u} 2>$null
                        if ($output) {
                            $behindCount = [int]$output
                            if ($behindCount -gt 0) { $isBehind = $true }
                        }
                    } catch { }

                    $statusMsg = if ($isBehind) { "$behindCount commits behind" } else { "Up to date" }
                    
                    $StatusList += [PSCustomObject]@{
                        Name = $pkg.Name
                        Status = $statusMsg
                        Id = $pkg.Id
                        NeedsAction = $isBehind
                    }
                    Pop-Location
                } else {
                    $StatusList += [PSCustomObject]@{
                        Name = $pkg.Name
                        Status = "Missing"
                        Id = $pkg.Id
                        NeedsAction = $true
                    }
                }
            }

            Write-Host "`nRepository Status:"
            $StatusList | Format-Table Name, Status, Id -AutoSize

            $actionsAvailable = $StatusList | Where-Object { $_.NeedsAction -eq $true }
            if ($actionsAvailable.Count -gt 0) {
                Write-Host "$($actionsAvailable.Count) repositories need updates or restoration." -ForegroundColor Green
                Write-Host "Run 'gitpkg pull all' to apply them, or 'gitpkg pull <name>' for a specific one.`n"
            } else {
                Write-Host "All repositories are up to date and present.`n" -ForegroundColor Green
            }
            exit 0
        }

        [array]$ReposToPull = @()
        
        if ($Target -eq "all") {
            $ReposToPull = $Packages
        } else {
            $ReposToPull = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }
            
            if ($ReposToPull.Count -eq 0) {
                Write-Host "Repository '$Target' not found." -ForegroundColor Yellow
                exit 1
            }

            if ($ReposToPull.Count -gt 1 -and $Target -eq $ReposToPull[0].Name) {
                Write-Host "`nMultiple repositories match '$Target'. Which one would you like to pull?" -ForegroundColor Yellow
                for ($i = 0; $i -lt $ReposToPull.Count; $i++) { Write-Host "  [$($i + 1)] $($ReposToPull[$i].Id)" }
                Write-Host "  [0] Cancel`n"

                $choice = Read-Host "Enter number"
                if ($choice -eq '0') { exit 0 } 
                elseif ($choice -match '^\d+$' -and [int]$choice -gt 0 -and [int]$choice -le $ReposToPull.Count) {
                    $ReposToPull = @($ReposToPull[[int]$choice - 1])
                } else { exit 1 }
            }
        }

        foreach ($pkg in $ReposToPull) {
            if (Test-Path $pkg.Path) {
                Write-Host "==> Pulling $($pkg.Id)..." -ForegroundColor Cyan
                Push-Location $pkg.Path
                & git pull --quiet
                Pop-Location
            } else {
                Write-Host "==> Restoring missing repository $($pkg.Id)..." -ForegroundColor Magenta
                $gitArgs = @("clone", "--depth", "1", $pkg.Url, $pkg.Path, "--branch", $pkg.Branch)
                & git @gitArgs
            }
        }
        
        if ($Target -eq "all") { Write-Host "All repositories processed." -ForegroundColor Green } 
        else { Write-Host "Successfully processed." -ForegroundColor Green }
    }

    'list' {
        [array]$Packages = Get-Packages
        if ($Packages.Count -gt 0) {
            $Packages | Format-Table Name, Branch, Hash, Id -AutoSize
        } else {
            Write-Host "No repositories tracked." -ForegroundColor Yellow
        }
    }

    'rm' {
        if (-not $Target) {
            Write-Host "Error: Target required. Usage: gitpkg rm <name|id|hash>" -ForegroundColor Red
            exit 1
        }
        
        [array]$Packages = Get-Packages
        [array]$pkgToRemove = $Packages | Where-Object { $_.Name -eq $Target -or $_.Id -eq $Target -or $_.Hash -eq $Target }

        if ($pkgToRemove.Count -eq 0) {
            Write-Host "Repository '$Target' not found." -ForegroundColor Yellow
            exit 1
        }

        if ($pkgToRemove.Count -gt 1 -and $Target -eq $pkgToRemove[0].Name) {
            Write-Host "`nMultiple repositories match '$Target'. Which one would you like to remove?" -ForegroundColor Yellow
            for ($i = 0; $i -lt $pkgToRemove.Count; $i++) { Write-Host "  [$($i + 1)] $($pkgToRemove[$i].Id)" }
            Write-Host "  [0] Cancel`n"

            $choice = Read-Host "Enter number"
            if ($choice -eq '0') { exit 0 } 
            elseif ($choice -match '^\d+$' -and [int]$choice -gt 0 -and [int]$choice -le $pkgToRemove.Count) {
                $pkgToRemove = @($pkgToRemove[[int]$choice - 1])
            } else { exit 1 }
        }

        $TargetPkg = $pkgToRemove[0]
        Write-Host "==> Removing $($TargetPkg.Id)..." -ForegroundColor Cyan
        
        if (Test-Path $TargetPkg.Path) { Remove-Item -Path $TargetPkg.Path -Recurse -Force }
        
        $Packages = $Packages | Where-Object { $_.Id -ne $TargetPkg.Id }
        Save-Packages $Packages
        Write-Host "Successfully removed." -ForegroundColor Green
    }

    'export' {
        $exportPath = if ($Target) { $Target } else { Join-Path (Get-Location) "gitpkg-export.json" }
        Copy-Item -Path $ConfigFile -Destination $exportPath -Force
        Write-Host "Successfully exported tracked repositories to:" -ForegroundColor Green
        Write-Host $exportPath -ForegroundColor Cyan
    }

    'import' {
        if (-not $Target -or -not (Test-Path $Target)) {
            Write-Host "Error: Please provide a valid path to a JSON file. Usage: gitpkg import <file.json>" -ForegroundColor Red
            exit 1
        }

        $importedData = Get-Content $Target -Raw | ConvertFrom-Json
        [array]$currentPackages = Get-Packages
        $addedCount = 0

        foreach ($pkg in $importedData) {
            if ($currentPackages.Id -notcontains $pkg.Id) {
                $currentPackages += $pkg
                $addedCount++
            }
        }

        Save-Packages $currentPackages
        Write-Host "Imported $addedCount new repositories from $Target." -ForegroundColor Green
        if ($addedCount -gt 0) {
            Write-Host "Run 'gitpkg pull all' to physically download the missing directories." -ForegroundColor Yellow
        }
    }
}