# Git Package Manager

A simple PowerShell script for managing git repos as packages. Clone repos into `~/gitpkgs`, track them in a manifest, and keep everything up to date — no package registry needed.

## Requirements

- PowerShell 7+
- Git in PATH

## Getting started

Just drop `gitpkg.ps1` somewhere on your machine and run it. No install step.

```powershell
.\gitpkg.ps1 Help
```

## Commands

### Add

Clones a repo into `~/gitpkgs` and records it in the manifest.

```powershell
.\gitpkg.ps1 Add BurntSushi/ripgrep
.\gitpkg.ps1 Add gitea.example.com:myorg/mytool
.\gitpkg.ps1 Add https://github.com/cli/cli
.\gitpkg.ps1 Add git@github.com:sharkdp/bat.git
```

If the target directory already exists and is a git repo, it gets recorded in the manifest without re-cloning.

### Get

Lists all installed packages in a table with their status and URL.

```powershell
.\gitpkg.ps1 Get
```

### Update

No argument — fetches all remotes and shows a table of what's up to date and what has commits waiting.

```powershell
.\gitpkg.ps1 Update
```

Pass `all` to actually pull every package, or a spec to update one.

```powershell
.\gitpkg.ps1 Update all
.\gitpkg.ps1 Update BurntSushi/ripgrep
```

### Remove

Deletes the repo directory and removes it from the manifest.

```powershell
.\gitpkg.ps1 Remove BurntSushi/ripgrep
```

Pass `-KeepFiles` to only remove it from the manifest, leaving the files on disk.

```powershell
.\gitpkg.ps1 Remove BurntSushi/ripgrep -KeepFiles
```

### Export / Import

Save your package list to a JSON file and restore it on another machine.

```powershell
.\gitpkg.ps1 Export .\packages.json
.\gitpkg.ps1 Import .\packages.json
```

Export without a path prints the JSON to stdout, handy for piping or quick inspection.

## Spec formats

All commands that take a repo accept a few different formats:

| Format | Example | Resolves to |
|---|---|---|
| `user/repo` | `cli/cli` | `github.com:cli/cli` |
| `host:user/repo` | `codeberg.org:user/tool` | `codeberg.org:user/tool` |
| HTTPS URL | `https://github.com/cli/cli` | as-is (`.git` appended if missing) |
| SSH URL | `git@github.com:cli/cli.git` | as-is |

## File locations

| Path | What it is |
|---|---|
| `~/gitpkgs/` | Where all repos are cloned |
| `~/.config/gitpkg/manifest.json` | Tracks installed packages |

## Flags

| Flag | What it does |
|---|---|
| `-KeepFiles` | Used with `Remove` — skips deleting the directory |
| `-Quiet` | Suppresses informational output |

## Support

If you find this helpful, consider supporting.

<a href="https://www.buymeacoffee.com/fahim.ahmed" target="_blank">
  <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
       alt="Buy Me A Coffee"
       style="height: 41px !important; width: 174px !important; box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5);" />
</a>