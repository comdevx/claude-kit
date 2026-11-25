---
name: command-safety-check
description: >-
  Strict pre-execution guardrail that reviews ANY command that could cause data
  loss, corruption, or irreversible system changes. Analyzes the FULL command
  (base command + flags + target + context) — not just the command name. Applies
  to ALL tools and databases (PostgreSQL, MySQL, Redis, MongoDB, Elasticsearch,
  etc.) — not limited to a fixed list. Classifies risk as CRITICAL / HIGH / MEDIUM
  based on actual impact. Triggers on: file deletion, recursive delete, force
  delete, disk format, git history rewrite, force push, database drop, table drop,
  truncate, bulk delete, cache flush, container prune, volume delete, infrastructure
  destroy, credential revoke, process kill, untrusted code execution, permission
  overwrite, data wipe, clean up, wipe, remove all, reset everything, nuke,
  destroy, purge, flush, drop.
---

# Command Safety Check

**Policy**: Before executing any potentially destructive command via Bash, analyze the FULL command (base command + flags + target + context). A command is only dangerous when its combination produces irreversible or significant data loss. This applies to ANY command on ANY OS (Linux, macOS, Windows, etc.) and ANY database client — not limited to a fixed list. If you know what a command does and it can destroy data, this policy applies.

**Scope**: CLI commands and database queries executed via Bash/shell only. Does NOT apply to code being written/edited in files — code has its own safety nets (code review, tests, deployment pipeline).

## 1. Command Analysis — Decompose Before Classifying

Break every command into 4 components before assessing risk:

| Component | What to check |
|---|---|
| **Base command** | The command itself — most commands are NOT dangerous on their own |
| **Flags/Options** | Which flags change the behavior to be destructive (`-rf`, `--force`, `--hard`, `-D`, `CASCADE`) |
| **Target/Scope** | What is being affected — a single file? a directory? root filesystem? production DB? How broad? |
| **Context** | Environment — local dev, staging, production? Is there uncommitted work? Are others using this branch? |

### Analysis principle

The examples below are representative, NOT exhaustive. Any command on any OS that deletes, overwrites, or destroys data must be analyzed the same way. If you recognize that a command can cause data loss — regardless of OS or tool — apply this framework.

### Analysis examples — File system

| Command | Analysis | Risk |
|---|---|---|
| `rm temp.log` / `del temp.log` | single specific file | **NONE** |
| `rm -rf node_modules` / `rd /s /q node_modules` | recursive, but target is regenerable | **MEDIUM** |
| `rm -rf src` / `rmdir /s /q src` | recursive, target contains source code | **HIGH** |
| `rm -rf /` / `del /s /q C:\` | recursive, target is entire filesystem | **CRITICAL + HARD STOP** |
| `git push` | no --force flag | **NONE** |
| `git push --force` to solo feature branch | force push, but only your own branch | **MEDIUM** |
| `git push --force origin main` | force push to shared main branch | **CRITICAL** |
| `git reset --hard` (clean tree) | no uncommitted changes to lose | **NONE** |
| `git reset --hard` (dirty tree) | will discard uncommitted changes | **HIGH** |
| `git branch -d feature` | safe delete — refuses if unmerged | **NONE** |
| `git branch -D feature` | force delete — skips merge check | **HIGH** |
| `docker stop my-container` | just stops, no data loss | **NONE** |
| `docker system prune -a --volumes` | removes all images AND data volumes | **HIGH** |

### Analysis examples — Database operations via CLI client (any database)

| Operation | Analysis | Risk |
|---|---|---|
| `SELECT * FROM users` | read-only query | **NONE** |
| `DELETE FROM users WHERE id = 5` | targeted delete with specific WHERE | **NONE** |
| `DELETE FROM users` | no WHERE — deletes all rows | **HIGH** (CRITICAL if prod) |
| `DROP TABLE users` | destroys table structure + data | **CRITICAL** if prod, **HIGH** if dev |
| `TRUNCATE users` | deletes all rows, no rollback in most DBs | **HIGH** |
| Redis `DEL key` | single specific key | **NONE** |
| Redis `FLUSHDB` | deletes all keys in current database | **HIGH** (CRITICAL if prod) |
| Redis `FLUSHALL` | deletes all keys in ALL databases | **CRITICAL** |
| Mongo `db.users.deleteOne({_id: x})` | targeted single document | **NONE** |
| Mongo `db.users.deleteMany({})` | empty filter — deletes all documents | **HIGH** (CRITICAL if prod) |
| Mongo `db.dropDatabase()` | destroys entire database | **CRITICAL** |
| Elasticsearch `curl -X DELETE /index` | deletes entire index + data | **HIGH** (CRITICAL if prod) |

## 2. Risk Classification — Based on Actual Impact

### CRITICAL — Irreversible data loss, no recovery possible

Classify as CRITICAL only when the **actual result** is permanent, unrecoverable data destruction:

- Filesystem: `rm -rf` targeting `/`, `~`, project root; `dd`/`mkfs` on mounted disk
- Git: `git push --force` to main/master/production branches
- Database (any): dropping production database, flushing all data (`DROP DATABASE`, `FLUSHALL`, `db.dropDatabase()`)
- Infrastructure: `terraform destroy` on production; deleting cloud resources with persistent data
- Security: revoking active production API keys or IAM roles
- Execution: piping untrusted source to shell (`curl | bash`)

### HIGH — Significant data loss, recoverable with effort

Classify as HIGH when data loss is significant but theoretically recoverable:

- Filesystem: `rm -rf` on directory with non-regenerable source/data
- Git: `git reset --hard` with uncommitted changes; `git branch -D`; `git push --force` to shared branch
- Database (any): bulk delete without filter (`DELETE FROM` no WHERE, `deleteMany({})`, `FLUSHDB`); dropping columns with data
- Containers: `docker system prune -a --volumes`
- Process: `kill -9` on a process managing persistent data
- Permissions: `chmod -R 777` on a directory

### MEDIUM — Disruption, quick recovery

Classify as MEDIUM when the impact is temporary and easily reversed:

- Deleting regenerable directories (`node_modules`, `.next`, `dist`, `build`, `target`, `__pycache__`)
- Deleting lock files (`package-lock.json`, `yarn.lock`, `Cargo.lock` etc.)
- `git stash drop`, `git stash clear`, `git tag -d`
- `docker-compose down -v`, `npm cache clean --force`, `cargo clean`
- `pip uninstall <package>`
- Clearing dev-only cache (Redis `FLUSHDB` on local dev)

### NOT DANGEROUS — No review needed

Do NOT flag these:

- Single specific file operations (`rm file.txt`, `DEL key`)
- Read-only operations (`SELECT`, `find`, `git log`, `docker ps`, `SCAN`, `db.collection.find()`)
- Targeted deletes with specific filter (`DELETE WHERE id=5`, `deleteOne({_id: x})`)
- Safe git operations (`git push`, `git branch -d`, `git stash`, `git reset --soft`)
- Non-destructive container ops (`docker stop`)
- Install/add operations (`npm install`, `pip install`)

## 3. Danger Escalation Factors

Escalate risk by ONE level **only when the command already has baseline risk**:

| Factor | When it escalates |
|---|---|
| Wildcard target (`*`, `**/*`, `.`) | When combined with destructive flags (`-rf`, `--force`) |
| `sudo` / root | When the destructive scope expands beyond user files |
| System paths (`/`, `/etc`, `/usr`, `~`) | When targeted by a destructive command |
| Unverified variable expansion (`$DIR`, `${VAR}`) | When the variable could be empty (empty = `/` in `rm -rf $DIR/`) |
| Production context | When targeting prod DB, prod server, prod branch |
| No prior dry-run | When the command supports `--dry-run`/`-n` but it wasn't used first |
| Piped destruction (`find | xargs rm`) | When the pipe feeds into a destructive command without preview |

## 4. Review Protocol

### MEDIUM risk

State the risk in one line. Suggest alternative if one exists. Proceed without waiting for confirmation.

```
[MEDIUM] Deleting node_modules — regenerable via `npm install`.
```

### HIGH risk

1. State exactly what data will be affected
2. Check reversibility — run `git status`, check for backups, check for version control
3. Present safer alternative FIRST
4. Ask for explicit confirmation before executing

```
[HIGH] `git reset --hard` will discard 3 uncommitted files.
Safer: `git stash -u` first (preserves changes, retrievable via `git stash pop`).
Proceed with reset --hard?
```

### CRITICAL risk

1. State exactly what will be permanently destroyed
2. Present safer alternative
3. Ask for confirmation
4. Restate the consequence and ask for FINAL confirmation (double confirm)

```
[CRITICAL] `git push --force origin main` will overwrite remote main history.
Other contributors will lose unmerged work.
Safer: `git push --force-with-lease origin main` (refuses if remote has new commits).

I will NOT execute this without explicit confirmation.
Please confirm: you want to force-push to main, overwriting remote history.
```

After first confirmation: "Final confirmation — this will permanently overwrite main on remote. Are you sure?"

## 5. Safer Alternatives

Present only when the command is flagged HIGH or CRITICAL:

| Flagged Pattern | Safer Alternative |
|---|---|
| `rm -rf <important-dir>` | `mv <dir> /tmp/<dir>-backup-$(date +%s)` → delete later |
| `rm -rf` + wildcard | `ls` or `find -print` first → delete specific items |
| `git reset --hard` (dirty tree) | `git stash -u` first |
| `git push --force` | `git push --force-with-lease` |
| `git clean -fd` | `git clean -fdn` (dry-run) first |
| `git branch -D` | `git branch -d` (safe: refuses if unmerged) |
| `DROP TABLE/DATABASE` | `pg_dump` / `mongodump` / backup first |
| `DELETE FROM` without WHERE | Add WHERE clause + `SELECT COUNT(*)` to preview |
| `TRUNCATE` | Backup table first |
| `FLUSHDB` / `FLUSHALL` (Redis) | `SCAN` + targeted `DEL` for specific keys |
| `db.dropDatabase()` / `.drop()` (Mongo) | `mongodump` backup first |
| `terraform destroy` | `terraform plan -destroy` first |
| `curl <url> \| bash` | Download file → review contents → execute |
| `docker system prune -a` | `docker system prune` (without `-a`, keeps tagged images) |
| `kill -9 <pid>` | `kill <pid>` (SIGTERM — allows graceful shutdown) |

## 6. Hard Stops — Refuse Execution Entirely

These commands are NEVER executed regardless of user confirmation:

- `rm -rf /` / `rm -rf /*` / `rm -rf ~/*`
- `dd` writing to a mounted system disk
- `mkfs` on a mounted filesystem
- Fork bomb: `:(){ :|:& };:`
- `> /dev/sda` or equivalent disk overwrite
- `chmod -R 777 /`
- Any recursive delete targeting `/`, `/home`, or `/etc`

Response: explain why this is blocked, suggest what the user likely intended, and offer a scoped alternative.
