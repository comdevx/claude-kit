# Skills and commands manifest

Every skill and command that was considered for the kit, where it comes from, under what
licence, and whether it ships in this repository. `Included = yes` means the files are in
`skills/` or `commands/`. Skills that are not bundled but are worth installing are listed in
the README under "Recommended skills".

Policy: a third-party skill is bundled only when its upstream licence allows redistribution
and the licence text ships inside the skill directory. Own-authored skills are bundled only
when they are useful to anyone on any OS; personal or project-specific ones stay private.

| Name | Category | Source | Licence | Included |
|---|---|---|---|---|
| fable-method | third-party | https://github.com/Sahir619/fable-method (unmodified copy) | MIT, (c) 2026 Sahir619; `LICENSE` in the skill dir | yes (permissive licence, core of the discipline rules) |
| fable-loop | third-party | same upstream (unmodified copy) | MIT, `LICENSE` in the skill dir | yes |
| fable-judge | third-party | same upstream (unmodified copy) | MIT, `LICENSE` in the skill dir | yes |
| fable-domain | third-party | same upstream (unmodified copy) | MIT, `LICENSE` in the skill dir | yes |
| fableexp-ci-gates | own-generic | authored in this kit (extends the Fable method) | MIT (kit licence) | yes |
| fableexp-migration-integrity | own-generic | authored in this kit | MIT (kit licence) | yes |
| fableexp-runtime-flow-verification | own-generic | authored in this kit | MIT (kit licence) | yes |
| fableexp-test-integrity-audit | own-generic | authored in this kit | MIT (kit licence) | yes (rule reference repointed to the kit rules) |
| command-safety-check | own-generic | authored in this kit | MIT (kit licence) | yes (non-English trigger words removed) |
| opus-escalation | own-generic | authored in this kit | MIT (kit licence) | yes (rewritten in English, owner hook references removed) |
| recheck | own-generic | authored in this kit | MIT (kit licence) | yes (needs the user's own Codex/Copilot/Cursor CLI) |
| playwright-search-fallback | own-generic | authored in this kit | MIT (kit licence) | yes |
| youtube-transcribe | own-generic | authored in this kit | MIT (kit licence) | yes (needs yt-dlp, ffmpeg, whisper installed by the user) |
| mockup-design | own-generic | authored in this kit | MIT (kit licence) | yes (machine paths and a private-project reference removed; needs Node and Playwright) |
| task-management | own-generic | authored in this kit | MIT (kit licence) | yes (hook path points at the kit's task-status hook) |
| dream | personal | authored by the kit author | n/a | no: operates on the author's private memory layout |
| apple-container | personal | authored by the kit author | n/a | no: author's macOS container policy and build queue |
| podman | personal | authored for the author's own servers | n/a | no: personal infrastructure reference |
| railway | personal | authored for the author's deployments | n/a | no: tied to the author's hosting setup |
| cloudflare-r2 | unknown provenance | origin not recorded | unknown | no: cannot confirm authorship or licence |
| pgsql | unknown provenance | origin not recorded, partly edited by the author | unknown | no: cannot confirm licence |
| svelte | unknown provenance | cites svelte.dev/docs/kit, origin not recorded | unknown | no: cannot confirm licence; use the official Svelte skills instead |
| (private project skills) | project-specific | a private game project; several skills are tied to it | n/a | no |
| graft | third-party tool skill | https://www.npmjs.com/package/@nanonets/graft (source repo MIT) | MIT | no: only useful once the graft CLI has indexed a repo; install it from upstream |
| reverse-engineer-anything | third-party | https://github.com/morluto/rea | MIT | no: needs the REA MCP server; recommended, install from upstream |
| playwright-cli | third-party | https://github.com/microsoft/playwright-cli | Apache-2.0 | no: tracks a fast-moving upstream; recommended, install from upstream |
| find-skills | third-party | https://github.com/vercel-labs/skills | MIT | no: recommended, install from upstream |
| stripe-best-practices | third-party | https://github.com/stripe/ai | MIT | no: niche (payments); recommended, install from upstream |
| upgrade-stripe | third-party | Stripe's skills (installed via `npx skills`); exact upstream path not verified | not verified | no: niche, licence not verified |
| vercel-react-best-practices | third-party | https://github.com/vercel-labs/agent-skills | skill header says MIT; the repository has no LICENSE file | no: redistribution terms not clear enough; recommended, install from upstream |
| web-design-guidelines | third-party | https://github.com/vercel-labs/agent-skills | no licence stated | no: no redistribution licence |
| synced/ (Claude.ai-synced skills) | third-party (Anthropic) | synced from Claude.ai | Anthropic terms | no: never redistributed |

## Commands

| Name | Category | Source | Licence | Included |
|---|---|---|---|---|
| fable-rules | own-generic | authored in this kit | MIT (kit licence) | yes (reads `~/.claude-kit/rules/discipline.md`) |
| review-team | own-generic | authored in this kit | MIT (kit licence) | yes |
| test-audit | own-generic | authored in this kit | MIT (kit licence) | yes |
