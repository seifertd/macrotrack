# MacroTrack

AI-assisted calorie/macro tracker for two people. Rails 8, PostgreSQL, installed as a PWA on two Android phones. Private, not a product.

- [`doc/macro-tracker-design.md`](doc/macro-tracker-design.md) — design doc (rev. 3): what it does and why.
- [`doc/IMPLEMENTATION-PLAN.md`](doc/IMPLEMENTATION-PLAN.md) — work packages, commands, verified environment facts.
- [`doc/macro-tracker-design-rev2.md`](doc/macro-tracker-design-rev2.md) — superseded rev. 2, kept for reference.
- [`CODE_REVIEW.md`](CODE_REVIEW.md) — whole-codebase review (2026-08-23) and what was fixed.
- [`.claude/AGENTS.md`](.claude/AGENTS.md) — production, deploys, and the traps that have already bitten.

Host: `macros.dseifert.net` → `capo`, Puma on `127.0.0.1:4001` behind nginx.

## How this was built

Built with Claude Code (the CLI, run locally) by one developer. The first commit was 2026-08-16. Everything through the code review shipped by 2026-08-23, and the work since then is maintenance.

### Spec first, then code

No application code was written until two documents were committed (`6f12e3e`, then `25a44d5` to settle the open decisions):

- **The design doc** says what the app does and argues why: two seeded users with no signup (§4), server-side speech-to-text instead of the Web Speech API (§6), the cheapest input first (§7), model choice (§8), the tool schemas (§15). Rev. 2 is kept so you can see what changed.
- **The implementation plan** turns the design into work packages. Each package has a goal, design references, and a **"Done when"** line. §0 lists environment facts that were *checked on the server, not assumed*. It also records where the build corrected the design doc, and the decisions that were made and flagged for disagreement.

When a decision in the code looks surprising, there is usually an argument for it in one of these two documents or in a comment next to the code.

### The agent

| Model | Commits carrying its `Co-Authored-By` trailer |
|---|---|
| Claude Opus 5 | 77: the original build and the review |
| Claude Opus 5.5 | 7: recent work |

The repo has 103 commits. 98 have a human author, and 84 of those are co-authored with Claude. The other 5 are from Dependabot. The agent works from [`.claude/AGENTS.md`](.claude/AGENTS.md), which is the same briefing a new human contributor should read.

### How the work was split

One Claude Code session did the work, with no subagents and no parallel sessions, **one package at a time**. Packages were picked in order of *what was most annoying in daily use*, not in plan order. After WP3, the plan says to use the app by hand for a few days before optimising anything. The order that shipped:

| Package | What | Done |
|---|---|---|
| WP1 | Rails skeleton, auth, schema, manual logging | 08-17 |
| WP2 | Capistrano deploy, systemd unit, nginx, PWA install | 08-17 |
| WP3 | Nightly backups, offsite pull, restore test | 08-17 |
| WP4, WP6a | Conversational logging (text); repeat meals | 08-18 |
| WP6b, WP4.4, WP7, WP7.5 | Matching, new foods, barcode, servings | 08-19 |
| WP4.5-a | Bulk import of structured food data | 08-21 |
| WP5-a, WP5-b | Voice: platform recognizer, then self-hosted whisper.cpp | 08-22 |
| Review | Whole-codebase review, top findings fixed | 08-23 |

A package was finished when a commit marked it done in the plan *with what was verified*: test counts, a real entry logged, a real restore. A ✅ alone didn't count. WP4.5-b and WP8–WP11 have not been built yet.

### What was checked by hand

**The developer reviewed the commits.** None of the agent's work went in unread.

`bin/rails test`, `bin/rubocop` and `bin/brakeman` cover the server side. Some things they can't see, so those were checked by hand. The plan records each one:

- **Time zones (WP1).** A meal stamped 23:30 local was logged and confirmed to be stored as 06:30 UTC the next day, shown as "11:30 pm", and filed on the previous day's page.
- **The installed PWA (WP2).** The first real meal was logged from the home-screen icon, not from a desktop browser.
- **Backups (WP3).** The previous night's dump was restored into a scratch database, and its row counts matched production.
- **Browser-only behaviour.** This covers the live calorie preview (WP6a), the barcode camera loop (WP7), and recording plus wake-lock on both phones (WP5). These are deliberately *not* in CI. The headless-Chrome system tests for the preview passed 2 runs out of 6 and were deleted. The plan's **thin-seam rule** keeps this untested surface small: any failure in it falls back to a server-rendered path that *is* tested.
- **Imported food data (WP4.5-a).** 61 edge cases were catalogued from real data. The CSV gets edited by a person before it is trusted. The plan explains why human review is where a whole class of correct-looking but wrong answers gets fixed.
- **The code review.** [`CODE_REVIEW.md`](CODE_REVIEW.md) measured query counts inside rolled-back transactions instead of guessing them from the code. It marks each finding fixed or *deliberately not done*, with reasons. The not-done items include changes, such as rate limits and `config.hosts`, that "want a deploy you are watching".
