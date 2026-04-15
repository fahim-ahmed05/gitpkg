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

### Clone

Clones a repo into `~/gitpkgs` and records it in the manifest. By default, the primary branch is cloned. To clone a specific branch, append `@branch_name` to the spec.

```powershell
.\gitpkg.ps1 Clone github.com:BurntSushi/ripgrep
.\gitpkg.ps1 Clone github.com:BurntSushi/ripgrep@develop
.\gitpkg.ps1 Clone gitea.example.com:myorg/mytool
.\gitpkg.ps1 Clone gitlab.com:group/subgroup/mytool@stable
.\gitpkg.ps1 Clone https://github.com/cli/cli
.\gitpkg.ps1 Clone https://github.com/cli/cli@latest-release
.\gitpkg.ps1 Clone ssh://git@gitlab.com/group/subgroup/project.git@feature-branch
.\gitpkg.ps1 Clone git@github.com:sharkdp/bat.git
```

If the target directory already exists and is a git repo, it gets recorded in the manifest without re-cloning.

Packages are stored in folders named `host@namespace@repo@branch` (for example, `github.com@BurntSushi@ripgrep@main`).

### List

Lists all installed packages in a table with canonical package IDs
(`host:namespace/repo@branch`), status, URL, and branch.

```powershell
.\gitpkg.ps1 List
```

### Pull

No argument — fetches all remotes and shows a table of what's up to date and what has commits waiting.

```powershell
.\gitpkg.ps1 Pull
```

Pass `all` to actually pull every package, or a spec to pull one.

```powershell
.\gitpkg.ps1 Pull all
.\gitpkg.ps1 Pull github.com:BurntSushi/ripgrep
```

### Remove

Deletes the repo directory and removes it from the manifest.

```powershell
.\gitpkg.ps1 Rm github.com:BurntSushi/ripgrep
```

Pass `-KeepFiles` to only remove it from the manifest, leaving the files on disk.

```powershell
.\gitpkg.ps1 Rm github.com:BurntSushi/ripgrep -KeepFiles
```

### Export / Import

Save your package list to a JSON file and restore it on another machine.

```powershell
.\gitpkg.ps1 Export .\packages.json
.\gitpkg.ps1 Import .\packages.json
```

Export without a path prints the JSON to stdout, handy for piping or quick inspection.

## Spec formats

All commands that take a repo accept a few different formats. For cross-host portability,
prefer a full clone URL. To clone a specific branch, append `@branch_name` (defaults to `main`).

| Format | Example | Resolves to |
|---|---|---|
| `host:namespace/repo[@branch]` | `codeberg.org:user/tool@stable` | `https://codeberg.org/user/tool.git`, cloned from stable branch |
| HTTPS URL with branch | `https://gitlab.com/group/subgroup/tool@develop` | as-is, cloned from develop |
| SSH URL (`ssh://`) | `ssh://git@gitlab.com/group/subgroup/tool.git@feature-x` | normalized to `ssh://user@host/path.git`, cloned from feature-x |
| SSH URL (scp style) | `git@github.com:cli/cli.git@latest` | as-is, cloned from latest branch |

Path rules:

- Namespace depth can be more than one segment (for example `group/subgroup/repo`).
- Repo path must be at least two segments (`namespace/repo`).
- `user/repo` shorthand is intentionally not supported to avoid host ambiguity.
- Branch is optional; if omitted, defaults to `main`.
- Multiple clones of the same repo with different branches are stored in separate directories.

## File locations

| Path | What it is |
|---|---|
| `~/gitpkgs/` | Where all repos are cloned |
| `~/.config/gitpkg/manifest.json` | Tracks installed packages |

## Flags

| Flag | What it does |
|---|---|
| `-KeepFiles` | Used with `Rm` — skips deleting the directory |
| `-Quiet` | Suppresses informational output messages (warnings/errors still show) |
| `-StatusCheckThrottle` | Max parallel workers for `Pull` status checks with no target (default `6`, range `1..32`) |
| `-NoParallelStatus` | Forces sequential status checks for `Pull` with no target |

## Support

If you find this helpful, consider supporting.

<a href="https://www.buymeacoffee.com/fahim.ahmed" target="_blank">
  <img src="https://www.buymeacoffee.com/assets/img/custom_images/orange_img.png" 
       alt="Buy Me A Coffee"
       style="height: 41px !important; width: 174px !important; box-shadow: 0px 3px 2px 0px rgba(190, 190, 190, 0.5);" />
</a>