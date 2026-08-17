# MacroTrack

AI-assisted calorie/macro tracker for two people. Rails 8, PostgreSQL, installed as a PWA on two Android phones. Private, not a product.

- [`doc/macro-tracker-design.md`](doc/macro-tracker-design.md) — design doc (rev. 3): what it does and why.
- [`doc/IMPLEMENTATION-PLAN.md`](doc/IMPLEMENTATION-PLAN.md) — work packages, commands, verified environment facts.
- [`doc/macro-tracker-design-rev2.md`](doc/macro-tracker-design-rev2.md) — superseded rev. 2, kept for reference.

The Rails app will be generated at the repository root (`rails new . --name=macrotrack`), so Capistrano deploys from the repo root the way the other apps on the box do.

Host: `macros.dseifert.net` → `das:4001` behind nginx.
