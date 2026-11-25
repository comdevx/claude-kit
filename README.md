# claude-kit

A portable, public starter kit for [Claude Code](https://docs.anthropic.com/en/docs/claude-code).
It installs a small set of working-discipline rules, hooks and skills into your Claude Code
profile, in one step, on macOS, Linux and Windows.

What you get:

- **Rules** that are loaded through a managed block in your `CLAUDE.md`: always-on core rules,
  verification and reporting discipline, and extra coding rules that are injected only when the
  session actually looks like a code task.
- **Hooks** that inject those rules at session start, detect code work automatically, and gate
  "done" claims (a stop gate that passes instantly when no source file changed).
- **Skills and commands** for verification, test auditing, safe command review, and more. See
  [`skills/MANIFEST.md`](skills/MANIFEST.md) for the full list with sources and licences.

The kit never overwrites your own content: it only edits the block between the
`<!-- claude-kit:begin -->` and `<!-- claude-kit:end -->` markers in `CLAUDE.md`, and only adds
or removes hook entries whose command path contains `/.claude-kit/`.

## Install

You download ONE file. Nothing needs to be cloned and git is not required.

macOS, Linux, or Git Bash on Windows:

```sh
# Option A: download, verify, run
curl -fsSLO https://github.com/comdevx/claude-kit/releases/latest/download/install.sh
curl -fsSLO https://github.com/comdevx/claude-kit/releases/latest/download/SHA256SUMS
sha256sum -c SHA256SUMS --ignore-missing      # macOS: shasum -a 256 -c SHA256SUMS --ignore-missing
bash install.sh

# Option B: one line
curl -fsSL https://github.com/comdevx/claude-kit/releases/latest/download/install.sh | bash
```

Windows PowerShell:

```powershell
# Option A: download, verify, run
Invoke-WebRequest https://github.com/comdevx/claude-kit/releases/latest/download/install.ps1 -OutFile install.ps1
Invoke-WebRequest https://github.com/comdevx/claude-kit/releases/latest/download/SHA256SUMS -OutFile SHA256SUMS
Get-FileHash install.ps1 -Algorithm SHA256     # compare with the matching line in SHA256SUMS
powershell -ExecutionPolicy Bypass -File .\install.ps1

# Option B: one line
irm https://github.com/comdevx/claude-kit/releases/latest/download/install.ps1 | iex
```

Each installer embeds the whole kit, so there is nothing else to download. The embedded payload's
SHA-256 is recorded at build time and checked before anything is extracted, so a corrupted or
truncated download is refused. That check (and `SHA256SUMS`, which `claude-kit update` also checks)
detects damage in transit; it cannot prove who published the release, and the installers are not
signed. For that, download `SHA256SUMS` yourself from the release page over HTTPS and compare it
with the installer before running it (Option A above). Pipe into `bash`, not `sh`: shells such as
dash read piped scripts ahead and the installer then stops (without changing anything).

The kit home must be a directory the kit owns: an existing, non-empty directory without the kit's
`.claude-kit-home` marker is never replaced, and HOME, a profile directory (or anything inside or
around one) and `/` are refused as `--kit-home`. The kit home is replaced on every update, so do
not edit files in it: customise in your own `CLAUDE.md`, outside the claude-kit block.

Each change is journaled to `~/.claude-kit/state/journal.jsonl` before it is made, so a run that is
interrupted (Ctrl-C, a crash, a full disk) can still be undone with `claude-kit uninstall`. Every
check that can fail (JSON that cannot be merged, directories that are not writable) runs before the
first write.

The kit files go to `~/.claude-kit` (`%USERPROFILE%\.claude-kit` on Windows), outside every profile.
Each profile only gets a small managed block in `CLAUDE.md`, the kit hook entries in `settings.json`
and links to the kit skills and commands. Every file the installer changes is backed up first
(`<profile>/.claude-kit-backups/<timestamp>/`), written to a temp file and then renamed into place.
Running the installer again is safe: the result is byte-identical and nothing is duplicated.

### Options

Without options the installer shows a menu on your terminal (this also works with `curl | bash`).
Without a terminal you must pass `--profile` or `--all`, otherwise it prints the usage and stops.

| Option | Meaning |
|---|---|
| `--profile <dir>` | Install into this Claude Code config dir. Repeatable. |
| `--all` | Install into every detected profile. |
| `--mode independent\|shared` | See "Profiles and modes". Default `independent`. |
| `--primary <dir>` | Shared mode: the profile the others link to. Default `~/.claude` (or the first selected). |
| `--share config\|config+history` | Shared mode: what is shared. Default `config`. |
| `--kit-home <dir>` | Where the kit files live. Default `~/.claude-kit` (or `$CLAUDE_KIT_HOME`). |
| `--no-cursor` | Do not touch Cursor at all (env `CLAUDE_KIT_NO_CURSOR=1`). |
| `--cursor-dir <dir>` | Use this Cursor config dir instead of `~/.cursor` (env `CLAUDE_KIT_CURSOR_DIR`). |
| `--no-cli` | Do not link the `claude-kit` CLI anywhere (env `CLAUDE_KIT_NO_CLI=1`). |
| `--bin-dir <dir>` | Link the `claude-kit` CLI into this dir (env `CLAUDE_KIT_BIN_DIR`); default `~/.local/bin` or `~/bin` when on `PATH`. |
| `--yes` | Answer yes to every question (installing `jq`, continuing while Claude Code runs, restoring backups on uninstall). |
| `--dry-run` | Print every planned change and touch nothing. |
| `--list-profiles` | Print the detected profiles and exit. |
| `--uninstall` | Same as `claude-kit uninstall`. |

### Testing / isolated install

To try the kit without touching your real setup, give it its own profile and kit home, and switch off
the two things that live outside a profile:

```sh
bash install.sh --profile /tmp/kit-try/.claude --kit-home /tmp/kit-try/kit --no-cursor --no-cli --yes
```

`--no-cursor` leaves `~/.cursor` alone and `--no-cli` creates no `claude-kit` link (or point them
elsewhere with `--cursor-dir` / `--bin-dir`). `--dry-run` prints every planned change with its absolute
path next to the `~` form. Uninstall and `claude-kit update` use what the install recorded in
`<kit home>/state/install.json`, not the flags of the later command, so an isolated install stays
isolated.

`jq` is required. If it is missing the installer offers to install it (brew, apt-get, dnf, pacman or
winget, asking first); otherwise it prints the exact command and stops before changing anything.

### Windows requirements

The hooks are bash scripts, so Windows needs **Git for Windows** (provides Git Bash) and **jq**.
If either is missing, the installer offers to install it for you with `winget`
(`winget install Git.Git`, `winget install jqlang.jq`). You can decline and install them yourself.

## Profiles and modes

The installer looks for Claude Code profiles in `$CLAUDE_CONFIG_DIR`, `~/.claude`, every
`~/.claude-*` and `~/.config/claude*` directory, and every directory assigned to
`CLAUDE_CONFIG_DIR` in your shell startup files (`.zshrc`, `.zprofile`, `.bashrc`, `.bash_profile`,
`.profile`, fish `config.fish`, and the PowerShell profile). A directory counts as a profile only if
it holds `settings.json`, `.claude.json`, `projects/`, `history.jsonl` or `sessions/`, so router,
provider and script folders that merely start with `.claude-` are ignored. Profiles that already
share files through symlinks are shown together, for example
`~/.claude-work (shares settings.json, CLAUDE.md, skills with ~/.claude)`, and a shared file is
merged only once.

Two modes:

- **Independent** (default): each selected profile gets its own `CLAUDE.md` block, its own
  `settings.json` merge and its own links to the kit skills and commands. If you already have a
  skill or command with the same name as a kit one, yours is kept and the kit one is skipped
  (reported in the output).
- **Shared**: you pick a primary profile, which gets the Independent install. In every other
  selected profile the shared items are replaced by symlinks to the primary's; the replaced
  originals are kept as `<name>.backup` (or `<name>.backup.<timestamp>`). Share levels:
  - `config`: `CLAUDE.md`, `settings.json`, `skills`, `commands`, `agents`, `output-styles`,
    `hooks`, `lessons`.
  - `config+history`: also `projects` (memory), `history.jsonl`, `plans`, `todos`,
    `file-history`, `sessions`, `plugins`, `shell-snapshots`, `paste-cache`, `image-cache`.

  Identity files are **never** shared: `.claude.json`, `.credentials.json`,
  `settings.local.json`, `mcp.json`, `statsig`, telemetry and security state. Every profile stays
  signed in to its own account. `settings.json` can also carry a profile's provider or credentials,
  so it is linked only when the identity-bearing keys (`env`, `apiKeyHelper`, `awsAuthRefresh`,
  `awsCredentialExport`, `forceLoginMethod`, `forceLoginOrgUUID`, `model`, `otelHeadersHelper`) are
  identical on both sides (also when both have none). If they differ in any way, including keys
  only the primary has, that profile is installed in Independent mode instead: none of its items
  are linked to the primary, so its own hooks, skills and provider settings keep working, and the
  installer prints one line saying why. Items that already link to the primary are left as they are; a
  profile that is the primary itself (through a symlink) or sits inside it is refused, so no link
  loops are possible. If Claude Code appears to be running, the installer warns and asks before
  relinking.

On Windows, symlinks need **Developer Mode** (Settings > System > For developers) or an admin
shell. Without them the installer falls back to directory junctions for folders, makes the
secondary `CLAUDE.md` a one-line `@<primary>/CLAUDE.md` import, gives the secondary its own
`settings.json` merge (with a note on enabling Developer Mode for true sharing) and copies the kit
skills instead of linking them. Hard links are never used. A kit copy you edited is never deleted:
update and uninstall move it to the profile's `.claude-kit-backups/` and say so.

## Cursor

If `~/.cursor` exists, the kit hooks are also merged into `~/.cursor/hooks.json` (your own Cursor
hooks are kept). Cursor has no code/non-code detection: its session-start hook injects one capped
block of rules (at most 10,000 characters) in this order: core rules, platform notes, discipline,
coding rules, then the tail of your lessons index. Whatever does not fit is cut from the end.

## Commands

The CLI is installed at `~/.claude-kit/bin/claude-kit`. If `~/.local/bin` or `~/bin` is on your
`PATH`, the installer links it there so you can just type `claude-kit`; otherwise it prints the full
path to use.

| Command | What it does |
|---|---|
| `claude-kit status` | Show installed version, kit home, profiles and mode. |
| `claude-kit profiles` | Detect profiles again and (re)configure them (menu, or the installer options). `--list` only prints them. |
| `claude-kit update` | Download the latest `install.sh` and `SHA256SUMS`, verify the checksum, and re-run it with your recorded profiles and mode. A mismatch is refused. |
| `claude-kit doctor` | Check `jq` and `bash`, that every kit hook path resolves, that shared links are still links, that rule files are within the size cap, that each `CLAUDE.md` has its block and that `settings.json` is valid JSON. Prints a fix for every problem. |
| `claude-kit uninstall` | Remove the managed `CLAUDE.md` blocks, the kit hook entries, and the links and copies the kit created (from its manifest only), then the kit home. Offers to restore each `.backup` the kit made (`--yes` restores them all); backups the kit did not make are never touched. A fresh install followed by an uninstall leaves your profile byte-identical. |

## Automatic code vs non-code detection

The always-on rules are short. The coding rules (tests, delegation, mockup gate, stop-gate
contract) are injected only once per session, and only when the session shows a code signal:
the first edit of a source file (or a shell command that writes one, such as `> file.ts`, `tee`,
`sed -i`, `cp`/`mv` onto a source path), in the main session or in a subagent. A chat about writing,
planning or research never pays for the coding rules, and a coding session picks them up
automatically without you asking.

The same hook logs every source edit to the kit's per-session state. The stop gate runs its
verifier only when that log has entries newer than its last "allow" decision, so research-only
subagents and chat never trigger it, while edits made by background agents are never missed.

## Recommended skills (not bundled)

These are good companions, but they are third-party work. They are not copied into this repo,
so they stay up to date and keep their own licences. Install them from the upstream source:

| Skill | Upstream | Licence |
|---|---|---|
| playwright-cli | https://github.com/microsoft/playwright-cli | Apache-2.0 |
| find-skills | https://github.com/vercel-labs/skills | MIT |
| vercel-react-best-practices, web-design-guidelines | https://github.com/vercel-labs/agent-skills | see the repository |
| stripe-best-practices | https://github.com/stripe/ai | MIT |
| Svelte / SvelteKit | https://github.com/sveltejs/ai-tools | MIT |
| reverse-engineer-anything (needs the REA MCP server) | https://github.com/morluto/rea | MIT |
| skill-creator | Anthropic's official skills | see upstream |

Bundled third-party work: the four `fable-*` skills are unmodified copies of
https://github.com/Sahir619/fable-method (MIT). Their licence is in each skill directory.

## Contributing

Run the tests with `bash tests/run.sh` (on macOS also `/bin/bash tests/run.sh`, which is bash
3.2). Build the installers with `bash build-release.sh` (committed tree of `HEAD`) or
`bash build-release.sh --worktree` (working tree, for local testing); the output is `dist/install.sh`,
`dist/install.ps1` and `dist/SHA256SUMS`. When publishing, pass `--repo <owner>/claude-kit` so
`claude-kit update` knows where the releases are. One test fails the build if any file in the repo
contains a personal path, an email address, or a private project name, so keep the kit generic.

## Licence

MIT, see [`LICENSE`](LICENSE). Bundled third-party skills keep their own licence, listed in
[`skills/MANIFEST.md`](skills/MANIFEST.md).
