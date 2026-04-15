# Git Package Manager

A lightweight Git repository manager for PowerShell. 

If you pull down a lot of random Git repositories to use as plugins (like mpv scripts, terminal themes, or shell tools) and hate manually tracking and updating them, this is for you. It treats Git repositories like packages, tracking them centrally and allowing for bulk updates, interactive removals, and cross-machine syncing.

## Features

* **Smart Cloning:** Automatically detects default branches and performs shallow clones to save disk space and time. Supports both HTTPS and SSH.
* **Collision Proof:** Hashes repository URLs and branches so you can install the main branch and a dev branch of the exact same tool side by side without folder conflicts.
* **Status Checks:** Run a dry pull to see exactly which repositories are outdated before you download any changes.
* **Auto-Healing:** If you accidentally delete a cloned folder, the script flags it as missing and automatically restores it on your next pull.
* **Portable:** Export your setup to a JSON file and import it on a new machine to instantly rebuild your environment.

## Installation

Download `gitpkg.ps1` and place it anywhere in your system. To make it feel like a native command, add an alias to your PowerShell `$PROFILE`:

```powershell
Set-Alias gitpkg C:\path\to\your\scripts\gitpkg.ps1
```

### Enable Tab Autocompletion
Add this snippet to your `$PROFILE` so you can hit Tab to autocomplete your installed repository names when pulling or removing:

```powershell
Register-ArgumentCompleter -CommandName gitpkg -ParameterName Target -ScriptBlock {
    param($commandName, $parameterName, $wordToComplete, $commandAst, $fakeBoundParameters)
    $ConfigFile = Join-Path $env:USERPROFILE ".config\gitpkg\repos.json"
    if (Test-Path $ConfigFile) {
        $packages = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        if ($packages) {
            $packages.Name | Where-Object { $_ -match "^$wordToComplete" } | ForEach-Object {
                [System.Management.Automation.CompletionResult]::new($_, $_, 'ParameterValue', $_)
            }
        }
    }
}
```

## Usage

### Install a repository
Just pass the URL. It will figure out the default branch automatically.
```powershell
gitpkg clone https://github.com/somedev/uosc
```

If you want a specific branch, pass it as the second argument:
```powershell
gitpkg clone git@github.com:somedev/uosc.git dev
```

### Update your packages
Run pull without arguments to check for updates across all your tracked repositories without actually downloading anything.
```powershell
gitpkg pull
```

To actually download the changes:
```powershell
# Update everything at once
gitpkg pull all

# Update just one specific package
gitpkg pull uosc
```

### See what is installed
Lists all tracked repositories, their current branch, and their unique hash.
```powershell
gitpkg list
```

### Remove a package
You can remove by name, exact ID, or hash. If multiple packages share the same name, gitpkg will prompt you with a numbered list so you don't delete the wrong one.
```powershell
gitpkg rm uosc
```

### Freeze & Unfreeze Packages
Prevent specific repositories from being updated during `gitpkg pull`. Frozen packages are automatically skipped during dry-runs and live pulls.

```powershell
# Freeze a package
gitpkg freeze uosc

# Unfreeze it later
gitpkg unfreeze uosc
```

### Git History
By default, gitpkg clones and pulls using --depth 1 (shallow). If you need full commit history switch to deep mode.

```powershell
# Fetch full git history on next pull
gitpkg deep uosc

# Revert back to shallow cloning
gitpkg shallow uosc
```

### Sync across machines
Export your current configuration to a JSON file:
```powershell
gitpkg export .\my-plugins.json
```

Import that JSON file on a new machine. It will register the packages and wait for you to run `gitpkg pull all` to handle the actual downloading.
```powershell
gitpkg import .\my-plugins.json
```

## Under the Hood

The script keeps configuration data separate from the actual payloads. 

* Config is stored in: `~/.config/gitpkg/repos.json`
* Repositories are cloned to: `~/gitpkg/`

To prevent name collisions, folders are named using a hash of their domain, path, and branch. For example, cloning `uosc` will result in a folder named something like `uosc@main-3f8a9b21`.