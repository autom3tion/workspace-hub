# Multi-repo workspace

A hub repo that clones a set of git repositories and generates VS Code multi-root workspaces
from them, with shared Copilot/agent instructions across all repos.

## Prerequisites

- `git`, PowerShell 7+ (`pwsh`) and VS Code.
- `code` on PATH (VS Code: **Shell Command: Install 'code' command in PATH**), needed for "open".
- Clone access to every repo in `repos.json` (SSH keys, or Git Credential Manager for HTTPS).
  The script runs a plain `git clone`; a repo you can't access shows as `ERROR` in the report
  and the rest still clone.

## Quick start

1. Clone this repo and open the folder in VS Code. Choose **Trust** when asked: tasks don't
   run in untrusted folders.
2. **Tasks: Run Task** → **Workspace: Sync + open workspace** → pick a tag (or "all").
3. In the new window, install the recommended extensions when prompted.

From now on, open the generated `*.local.code-workspace` file instead of the plain folder; re-run
**Workspace: Sync repos** to pull the latest changes.

Or from a terminal:

```bash
pwsh scripts/setup.ps1 -Tag backend -Name backend -Open
```

| Flag | Effect |
|---|---|
| `-Tag a,b` / `-Only x,y` | Select repos by tag or name (union). None → all non-optional repos |
| `-Name n` | Writes `<workspaceName>.n.local.code-workspace` |
| `-NoGit` / `-NoPull` | Only regenerate the workspace / fetch without pulling |
| `-IncludeWorktrees` | Add each repo's git worktrees as folders |
| `-Open` | Open the result with `code` |

Re-running is safe: repos that are dirty or not on their default branch are fetched but never touched.

## Using this as a template

The repos in `repos.json` are examples with placeholder URLs. For your own hub:

1. Replace the entries in `repos.json` with your repos (schema: `repos.schema.json`).
2. Fill in `docs/projects/<name>.md` for each repo (start from `_template.md`).
3. Update the tag list in `.vscode/tasks.json` (`inputs` → `tag`) to match your tags.
4. Optionally set `workspaceName` and `extensions` in `repos.json`.

## Layout

```
repos.json                    manifest (source of truth)
scripts/setup.ps1             clone/update + workspace generator
.vscode/tasks.json            VS Code tasks wrapping the script
.github/copilot-instructions.md   workspace-wide agent rules
docs/projects/<name>.md       per-repo overview for agents and humans
repos/, worktrees/            clones (gitignored)
```

## Agent instructions

The hub is always the first folder in a generated workspace, so `.github/copilot-instructions.md`
applies across all repos. Repo-specific rules belong in each repo's own
`.github/copilot-instructions.md` or `AGENTS.md`. Check which ones were used under **References**
in a Copilot Chat answer.
