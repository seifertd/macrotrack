# MacroTrack — Implementation Plan

Companion to `macro-tracker-design.md` (rev. 3). That doc says *what and why*; this one says *in what order, with which commands, and how you know a step is done*.

Ordered so the app is on both phones by the end of WP2, sharing meals between the two of us by the end of WP6a, logging by conversation by the end of WP4, and logging by voice by the end of WP5-a.

**Build order:** WP1 → WP2 → WP3 → **WP6a** → WP4 → **WP6b** → **WP7** → **WP7.5** → **WP4.4** → **WP4.5-a** → **WP5-a** → **WP5-b** → WP8 → WP9 → WP10.

**Next: WP8** — weight + trends. WP9 cannot start until it has history to fit. **WP4.5-b is not scheduled** — it has three open questions and no deadline, because the backlog it would have served is already imported.

Numbers are stable identifiers, not sequence. Three packages have moved since the first draft — barcode ahead of voice, and repeat-meals ahead of everything else — and keeping their numbers means existing cross-references still resolve. The reordering rule has been the same each time: **whatever removes real friction soonest, for the least work.**

---

## 0. Environment facts (verified, not assumed)

I probed the local machine and `das` before writing this. These are checked, current as of 2026-08-16:

| | Finding |
|---|---|
| Local Ruby | 3.4.9, Rails 8.1.3.1, bundler 4.0.17, node 26.7.0 |
| Local Postgres | **not installed** — no `psql`. Arch/CachyOS repo carries **18.6**, which is the version we want |
| Local docker / kamal | **neither installed** |
| Deploy host | `das`, Ubuntu 22.04.5 LTS |
| Host Postgres | **14.23**, running on `127.0.0.1:5434` (not 5432), `pg_trgm` contrib present — **being replaced by 18.x, see below** |
| das → GitHub | ✅ SSH as `seifertd` already works (verified) — Capistrano needs no new deploy key |
| Repo | ✅ `git@github.com:seifertd/macrotrack.git`, private, `main` pushed |
| Host web tier | nginx, per-app vhost in `/etc/nginx/conf.d/<app>.conf`, `upstream` → `localhost:<port>`, certs by certbot |
| Ports in use on das | 3000, 3001, 4000 (Rails apps), 3306 (MySQL), 5434 (PG) → **4001 is free** |
| Deploy tooling in use | Capistrano 3 + `capistrano-rvm` + systemd **user** unit from `config/deploy/templates/systemd_service.erb` |
| App layout on host | `/home/doug/webapps/<app>/production/{current,shared,releases}` |
| Ruby on host | system RVM at `/usr/local/rvm`, per-app gemsets |
| Existing apps' DB | all SQLite (chord-practice, bbo-free) — MacroTrack would be the first Postgres app |

### The two-user assumption is gone (2026-08-17)

Design doc rev. 3 asserted a two-person household *in code* — `User.where.not(id: user.id).sole` — and defended it as "an assertion of the app's core assumption." That was wrong, and it's now fixed in both documents and the schema.

The problem wasn't that two is the wrong number today; it's that "the other user" is not a local assumption. It appeared in a **tool schema**, a **dispatcher**, and a **UI affordance**, so a third account would have meant editing all three plus every query that said "both users." That's the definition of an assumption that's cheap to allow for now and expensive to retrofit.

**What changed:** a `households` table, `users.household_id`, and sharing scoped to the household rather than to "every row in `users`". `copy_to_household_member` now takes a `member_name`; with exactly one other member the model may omit it, and with several an ambiguous request comes back as an `is_error: true` tool result so the assistant asks instead of guessing.

**What did not change:** two people is still the *design case*. There's still no signup route, the "also log for" affordance still renders as one button naming one person, and the UI is still tuned for a household of two. `foods` stays global rather than per-household — a nutrition database has no reason to be private.

### Three corrections to the design doc

1. **§3 says "deployed with Kamal." Don't.** There's no docker on your laptop or (as far as the probe shows) a docker workflow on das, and every app on that box is Capistrano + RVM + systemd + nginx. Copy `chord-practice`'s deploy setup instead — you already know it works, and it's a 20-minute adaptation rather than a new deployment system to learn. Kamal on a box already running four non-containerized apps behind hand-written nginx vhosts buys you nothing here.
2. **Postgres is not on 5432 on das, and we're not using the version that's there.** The existing cluster is 14.23 on `127.0.0.1:5434`. We're going to **18.x** (see the version decision below), which means a *second* cluster on its own port — `5435` is the obvious pick. Whatever it ends up being, `database.yml` needs an explicit `port:` in every environment that talks to das. This is the kind of thing that costs an hour on deploy day if it isn't written down.
3. **Rails 8's auth generator names the column `email_address`, not `email`.** The design doc's §5 schema says `email`. Keep the generator's name and adapt the doc — fighting the generated code to rename one column is pure downside.

### Decisions I'm making for you (flag if you disagree)

- **Postgres, not SQLite**, despite every other app on the box being SQLite. `pg_trgm` is load-bearing for §7's repeat-meal matching, which is the single highest-leverage feature in the doc. SQLite's FTS5 is a worse fit for short fuzzy food names.
- **Postgres 18.6**, both locally and on das. That's the current stable major (18 shipped September 2025; 18.6 is the current minor, released 2026-08-13). Two consequences worth knowing:
  - **PG 19 GA lands ~September 2026 — a few weeks out**, with beta 3 already published. Don't take it. §13 of the design doc says pin dependencies and don't chase upgrades, and running a one-month-old major under your food log is exactly the kind of unforced risk that section is about. Revisit at 19.2, next year.
  - Upgrading das gets you off **PG 14, which reaches end-of-life in November 2026** — so this isn't gold-plating, it's a thing you'd have to do anyway. New cluster on its own port, old 14 cluster left alone for whatever else uses it.
- **Keep Rails 8's generated four-database production config** (primary/cache/queue/cable). It costs four `CREATE DATABASE`s and `db:prepare` handles all of them; deviating means hand-editing the Solid* connects_to config.
- **Solid Queue inside Puma** (`SOLID_QUEUE_IN_PUMA=1`), not a second systemd unit. Two users, a handful of jobs a day. One process to supervise.
- **Propshaft + importmap + tailwindcss-rails**, the Rails 8.1 defaults. chord-practice is on sprockets, but that's history, not a preference to inherit.
- **Hostname: `macros.dseifert.net`.** You already run `www.dseifert.net` off this box, so DNS and certbot are familiar ground. It appears in exactly three places (nginx vhost, Capistrano config, `config.hosts`), so renaming stays cheap.

### On deferring subdomain-vs-subpath

Deferring the *real DNS record* is free. Deferring the **subdomain-vs-`www.dseifert.net/macros` decision past WP2 is not**, and it's worth being clear why:

- **Local development doesn't need either.** `localhost:3000` is a [secure context](https://developer.mozilla.org/en-US/docs/Web/Security/Secure_Contexts), so `getUserMedia`, `MediaRecorder`, service workers, and `BarcodeDetector` all work over plain HTTP on localhost. You can build every feature through WP5 with no hostname, no cert, no `/etc/hosts` entry.
- **An `/etc/hosts` entry buys less than it looks like.** It only helps the machine you edit. **Android has no usable `/etc/hosts`**, so the phones can't be pointed at das that way — and getting it onto the phones is the entire point of WP2. Phone testing needs a real A record and a real cert, full stop. (An `/etc/hosts` entry on the laptop is still handy for one thing: checking the nginx vhost and `config.hosts` before DNS propagates.)
- **A subpath costs real work, and most of it lands in the PWA layer.** `config.relative_url_root`, the nginx `location` block, asset path prefixing, and — the annoying one — **a service worker can only control URLs at or below its own path**, so it must be served from `/macros/sw.js` with a matching `start_url` and `scope` in the manifest. Get this wrong and the install prompt either doesn't appear or the installed app scopes to the whole of `www.dseifert.net`.

**Settled 2026-08-17: subdomain.** `macros.dseifert.net`, PWA at scope `/`, every default works as generated. The subpath complications above are now moot — recorded only so the reasoning survives if it ever comes back up. The remaining action is the **DNS A record**, which is a WP2 blocker with propagation lead time.

---

## 1. Prerequisites — before WP1

- [x] **Private GitHub repo.** `git@github.com:seifertd/macrotrack.git`, `main` pushed, docs under `doc/`. The Rails app will be generated at the repo *root* (`rails new . --name=macrotrack`) so Capistrano's layout matches the other apps on the box.
- [x] **das can pull from GitHub.** Verified: `ssh -T git@github.com` from das authenticates as `seifertd`. No deploy key needed.
- [x] **Postgres 18.6 installed locally**, running under systemd on the default 5432. `initdb` set local auth to **trust**, so no password is needed for dev connections, and it picked up `America/Los_Angeles` as the cluster timezone on its own. Role `doug` is a superuser.
- [x] **Install Postgres 18 on das** — done 2026-08-17 via the PGDG apt repo (`jammy-pgdg`), `postgresql-18` 18.6. Two corrections to what this line originally said: there is no `postgresql-contrib-18`, because contrib modules (including `pg_trgm`) ship inside the main `postgresql-18` package; and installing it in the same transaction that *upgrades* `postgresql-common` skips the automatic cluster creation, so `pg_createcluster 18 main --start` was needed by hand. The old PG 14 cluster held nothing but the three system databases and was dropped and purged. **18/main is on port 5432.**
- [x] **Postgres role and databases on das** — created by `script/setup_production_db.sh`, which is idempotent and reads the port from `pg_lsclusters` rather than hardcoding it. The four databases are pre-created and owned by `macrotrack`, so the role needs no `CREATEDB`. `pg_trgm` is created by the superuser up front, which turns the migration's `enable_extension` into a no-op. The password is generated on the host and written straight into `shared/config/database.yml` (mode 600, a Capistrano `linked_file`) — it is not in Rails credentials.
- [x] **`pg` gem compiles on das** — verified by the first deploy's `bundle install`.
- [x] **DNS A record** for `macros.dseifert.net` → `45.79.27.47`. Authoritative on Namecheap's `registrar-servers.com` nameservers (not Linode DNS), propagated, and TLS issued.
- [x] **Anthropic API key** — in `config/credentials.yml.enc` under `anthropic.api_key`, added 2026-08-18. A Claude Pro subscription does **not** include API access; this is a separate Console org on prepaid credit. An STT provider key (§2 below) is **not** needed unless WP5-b is built — WP5-a uses the platform's own recognizer and calls nothing. Note the deploy step in WP4 — the credentials file is a Capistrano linked file, so a key added locally does not reach das until it is copied up.

---

## 2. STT provider shortlist

Design ref: §6, which says **select on accuracy of food nouns, not latency**. Pricing verified August 2026; re-check before you sign up, but the magnitudes are stable and the *ranking* is what matters.

Your volume, from §6: 2 people × ~5 entries/day × ~15s ≈ **75 minutes/month**. That is the number that makes this table almost a joke.

| Provider / model | Price | Your monthly bill | Vocabulary biasing | Notes |
|---|---|---|---|---|
| **Deepgram Nova-3** (batch) | $0.0043/min | **$0.32** | **Keyterm Prompting** — up to 100 plain terms, claims up to 90% keyword recall | Purpose-built biasing, cheap, fast. The strongest fit for our 40-food hint. |
| **AssemblyAI Universal-3 Pro** (async) | ~$0.21/hr ≈ $0.0035/min | **$0.26** | **`keyterms_prompt`** — up to 1,000 words/phrases, plus a separate natural-language prompt | Highest term limit by far. Ceiling grows as `foods` grows. |
| **Groq**, `whisper-large-v3-turbo` | **$0.04/hr ≈ $0.00067/min** | **$0.05** | Whisper `prompt` (~224 tokens) | Absurdly cheap, ~228× realtime. 10-second minimum billing. Whisper-class food-noun handling, weaker biasing than the two above. |
| **OpenAI** `gpt-4o-mini-transcribe` | ~$0.003/min | **$0.23** | `prompt` parameter | Fine, unremarkable. |
| **OpenAI** `gpt-4o-transcribe` | ~$0.006/min | **$0.45** | `prompt` parameter | The figure §6 quotes. No reason to prefer it over the above. |
| **Self-hosted `whisper.cpp`** on das | $0 + CPU | **$0** | Whisper `prompt` | `small.en` on CPU does a 20s clip in a few seconds — inside §6's budget. A dependency decision, not a cost one. |

**The bill is between five cents and forty-five cents a month.** Every option is free in practice, so *ignore price entirely* and pick on food nouns. Concretely:

- **Start with Deepgram Nova-3.** Keyterm Prompting is the closest thing on the market to the feature §6 designed — it takes a plain list of up to 100 terms, which is exactly the shape of that `Food` query, and it's aimed at precisely this problem (jargon and long-tail entity recall). AssemblyAI is the other serious candidate and its 1,000-term ceiling ages better; it's a coin flip, so let the bake-off decide.
- **Whisper-family biasing is genuinely weaker.** The `prompt` parameter is a soft nudge, not a keyword booster — published results show useful but modest gains (~17% relative WER reduction on proper-noun-dense speech). Fine, not the same thing.
- **Groq is the wildcard worth one extra column in the bake-off.** At $0.05/month with 228× realtime, if its raw Whisper transcription happens to nail your foods, nothing else can compete on simplicity-per-dollar.
- **Watch the add-on trap.** Advertised base rates assume no extras; diarization, redaction, and summarization can multiply the effective rate 2–4×. You need none of them — plain transcription plus keyterms. Don't let a dashboard talk you into more.

**Do the bake-off before writing any hosted-STT UI.** One real 20-second clip of one of you rambling about dinner, four providers, count the food nouns each one gets right. Free tiers cover this comfortably.

**Add two more columns, and they are both free incumbents.** The phone keyboard's own dictation logged the first four real meals on 2026-08-18 and got every food noun right; the platform recognizer WP5-a is built on is the same class of thing with one less tap. A paid provider has to be *visibly* better than the better of those two before it earns the dependency. Make the clip hard enough to actually separate them: a recipe name, a self-correction, kitchen noise.

**This whole section is now gated behind WP5-b** (split 2026-08-22), and 5-b is unscheduled — it waits on evidence from 5-a that on-device recognition isn't enough. Nothing here is on the critical path until then; re-verify the prices when it comes off the shelf.

---

## WP1 — Skeleton, auth, manual logging ✅ *done 2026-08-17*

**Result: 34 tests, 108 assertions, 0 failures. Rubocop clean.** Verified by hand as well as by the suite: signed in, logged a 780 kcal burrito bowl stamped `23:30` local, and confirmed it stored as `2026-08-17 06:30 UTC`, rendered as "11:30 pm", and landed on the **2026-08-16** day page. Two things worth knowing about the local dev database: it's seeded with password `development` for both users (change it, or don't — it never leaves the laptop), and that burrito bowl is still in there as sample data.

Design refs: §4, §5, §14.1. **Goal: two people can log a meal by typing numbers into a form, and see a day total.** No AI yet.

```bash
cd /home/doug/Projects/ai-calorie-tracker
rails new . --name=macrotrack \
  --database=postgresql \
  --css=tailwind \
  --javascript=importmap \
  --skip-kamal --skip-docker --skip-jbuilder
bin/rails generate authentication
bundle add anthropic
bundle add faraday faraday-multipart   # for the STT multipart upload in WP5
```

Generating into `.` keeps the Rails app at the repo root, which is what Capistrano expects. `--name` is required because the directory is `ai-calorie-tracker` while the app is `macrotrack`.

Then:

1. **Migrations.** Take §5's schema verbatim except: `email` → `email_address` (generator's name), and add `enable_extension "pg_trgm"` in its own migration ahead of `foods`. Create all six tables now — `weight_entries` and `exercise_entries` cost nothing to create and their schema won't change, and having them present means WP8/WP9 are pure app code.
2. **Strip signup.** Delete the registration route and any signup link in the generated views. Seed two users in `db/seeds.rb` with **`timezone: "America/Los_Angeles"`** set explicitly — the design doc is emphatic that timezone is not optional, and the schema default of `"UTC"` silently misfiling every 11pm snack onto tomorrow is exactly the bug it's warning about. Also set `name` on both (see below).

   **What `users.name` is for.** It's a short display name — a first name — and it exists because this is a two-person app where entries cross between people. It shows up in four places:

   - the **"also log for \<name\>"** button on every entry (§7's household affordance) — the button has to say *whose* day it's copying to;
   - the confirmation the assistant reads back after `copy_to_household_member`, which returns `to: other.name` (§16);
   - the **trends tab**, where both of your weight lines share one chart and need a legend (§10);
   - anywhere an entry with `source: "copied"` is shown, so you can tell "she logged this and it came to me" from "I logged this."

   It is **not** a login credential — you sign in with `email_address` — and it's never shown to anyone outside the household. So: your first names, or whatever you'd actually want to read on a button. `"Doug"` and hers.
3. **Session lifetime.** `expires: 1.year` on the session cookie so neither of you sees a login screen twice.
4. **`User#day_totals(time)`** — sums `meal_entries` for the local date derived through `user.timezone`. This is the single most-called method in the app; write its test first and make the timezone boundary a test case (an entry at 23:30 local and one at 00:30 local land on different days).
5. **Manual entry form + day list + header strip.** Plain Rails, no Turbo cleverness yet.

**Done when:** you can log in as either user on your laptop, add an entry by hand, and the header strip shows the right total — including for an entry timestamped late last night.

---

## WP2 — Deploy + PWA install ✅ *done 2026-08-17*

**Result: live at https://macros.dseifert.net.** Puma on 4001 with the Solid Queue supervisor running inside it, behind nginx with a Let's Encrypt cert good to 2026-11-15 and an HTTP→HTTPS redirect. `/manifest`, `/service-worker`, and both icons serve 200; Doug and Raquel are seeded and can sign in. Suite: 41 runs, 144 assertions, 0 failures.

Four things worth knowing that this section didn't anticipate:

- **The systemd unit and the nginx vhost are both version-controlled now.** The unit renders from `config/deploy/templates/systemd_service.erb` on every deploy, with the rvm wrapper path derived from `.ruby-version`/`.ruby-gemset`. The vhost lives at `config/deploy/nginx/`; `nginx:check` reports drift on every deploy and `nginx:install` handles the rest, except the final `sudo` — see below.
- **`db:migrate` was the wrong migration command.** Solid Cache/Queue/Cable are defined by `db/*_schema.rb` with no migrations of their own, so `db:migrate` left them empty. `set :migration_command, "db:prepare"` in `config/deploy.rb` fixes it.
- **Don't install libvips.** The `Using vips to process variants requires the libvips library` warning from `db:prepare` is benign. Jammy's libvips is 8.12.1, and Active Storage 8.1 hard-raises on anything below 8.13 — installing it *breaks app boot*, and `apt-get install libvips` also drags in ~30 desktop packages including a GTK2 image editor. The app's only blobs are audio, which Active Storage analyzes with ffprobe.
- **sudo on das needs a password**, so nothing privileged can be automated from `cap`. The nginx install task stages the file and prints the commands rather than pretending otherwise.

Design refs: §3, §10 PWA specifics, §14.2. **Goal: it's on both phones, and `git push && cap production deploy` is the release process.** Do this before any AI work — the doc is right that three days of real use beats three days of design, and that only starts when it's on the phones.

1. **Copy Capistrano config from chord-practice**: `Capfile`, `config/deploy.rb`, `config/deploy/production.rb`, `config/deploy/templates/systemd_service.erb`, and the capistrano gems in the `:development` group. Change: `:application` to `macrotrack`, `:repo_url`, `deploy_to` → `/home/doug/webapps/macrotrack/production`, app port → **4001**, `.ruby-gemset` → `macrotrack`.
2. **Adapt the systemd template**: add `Environment="SOLID_QUEUE_IN_PUMA=1"` so the job supervisor comes up with the web process. Confirm `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` is present in `config/puma.rb` (Rails 8 generates it).
3. **`linked_files`**: `config/database.yml`, `config/master.key`, `config/credentials.yml.enc`, `config/credentials/production.key`. **`linked_dirs`**: the chord-practice list plus **`storage`** — Active Storage will hold the audio blobs from WP5 and they must survive a release swap.
4. **Production `database.yml` on the host** (in `shared/config/`) with `host: 127.0.0.1`, `username: macrotrack`, password from credentials, and **the PG 18 cluster's port** — confirm with `pg_lsclusters`, don't assume 5432 (14 is already squatting on 5434).
5. **nginx vhost** `/etc/nginx/conf.d/macros.dseifert.net.conf`, modeled on chord-practice's: `upstream macrotrack { server localhost:4001; }`, asset caching block, and **`client_max_body_size 25M`** — voice uploads are small, but the default 1M will bite you the first time you ramble for 90 seconds. Then `sudo certbot --nginx -d macros.dseifert.net`.
6. **PWA bits**: `manifest.json` (`display: "standalone"`, `start_url: "/"`, `theme_color`, 192px and 512px icons), a minimal service worker registered on first load. Skip `apple-touch-icon`.
7. **Install on both phones** via Chrome → Install app. Verify it lands in the app drawer with its own task-switcher entry.

**Done when:** both of you have logged a real meal from your phone, from the home-screen icon, over HTTPS, and a `cap production deploy` of a trivial change shows up without reinstalling.

*Met on Doug's phone: installed from Chrome, and a 559 kcal / 360 g portion of burst cherry tomato pasta logged from the home-screen icon at 12:09 pm local — stored as `19:09 UTC` and rendered on the correct day, which is the timezone path WP1 was built around. Raquel's phone install is the one piece still outstanding.*

**Then use it manually for a few days.** Everything after this is friction reduction; you want to know which friction actually annoys you before optimizing it.

---

## WP3 — Backups ✅ *done 2026-08-17*

**Result: two-machine backup, restore-tested.** das dumps nightly at 02:15 and prunes at 30 days; the xbmc box (`seifert-media`) pulls at 03:15 into `/media/backup/macros-backups/` and keeps everything. The restore test loaded the day's dump into a scratch database and matched production exactly — `users=2 meal_entries=1` on both sides — then dropped the scratch database.

Three things this section didn't specify, decided during the build:

- **Custom format, not plain SQL + gzip.** `pg_dump -Fc` is already compressed and lets `pg_restore` do selective and parallel restores off the same file. Both scripts check that a dump actually contains table data, because `pg_dump` exits 0 on an empty result and a useless backup is otherwise indistinguishable from a good one by size alone.
- **The offsite copy pulls; das never pushes.** So das holds no credential for the media box. The key is a dedicated ed25519 pair generated on xbmc and restricted on the das side to `command="/usr/bin/rrsync -ro /home/doug/webapps/backups/macrotrack",restrict` — read-only, that directory only, no shell, no forwarding.
- **Only the primary database is dumped.** cache/queue/cable are Solid-* scratch state, regenerable from `db/*_schema.rb`.

Both halves write a `last_success` marker and check its age rather than trusting the directory listing, since a cron that quietly stopped leaves a directory full of yesterday's dumps that looks perfectly healthy.

Design refs: §13. The doc says this "arguably belongs at step 2." It does — move it here. You now have real data and no copies of it.

- Nightly cron on das: `pg_dump` (with the `-p 5432`) → gzip → `/home/doug/webapps/backups/macrotrack/`, retain 30 days.
- `rsync` that directory to a home machine, or push to object storage. One of the two, not neither.
- Restore-test it **once, now**: load last night's dump into a scratch database and count rows. An untested backup is a belief, not a backup.

**Done when:** you have restored a dump you didn't create by hand.

---

## WP6 — Repeat meals + portioned "also log for" *(target: one evening for 6a, one for 6b)*

**Moved ahead of WP4 on 2026-08-17**, and rewritten. Raquel's first request after using the app was: *let me pick from meals Doug already entered and say how much I ate* — and vice versa. That needs no AI at all, it's the friction that exists **today**, and the plan already called this package the highest leverage per hour of work in the whole document. Building it before the biggest package in the plan is the obvious trade.

Design refs: §7 (path 1 and the household affordance), §14.5. Zero AI cost.

### The correction: copying is portioned, not verbatim

§7 and `copy_to_household_member` (§16) both copy an entry **verbatim** — same macros onto the other person's day. That's wrong for this household. Doug's targets are 2000 kcal and Raquel's are 1600; they eat the same dinner in different amounts. A verbatim copy is wrong for whoever didn't cook, and "copy then edit" makes the person with the smaller portion do the extra work every single time.

**So the copy takes a portion.** Entries already carry `quantity_grams` alongside absolute macros, so scaling is `new_grams / original_grams`, applied to calories and all three macros. Where the source entry has no `quantity_grams`, fall back to a plain multiplier (½, 1, 1½, 2) — always offer the multiplier as well, because "half of what he had" is often the honest answer and nobody wants to weigh a bowl to answer it.

### WP6a — pick and portion ✅ *done 2026-08-18*

**Result: 128 tests, 454 assertions, 0 failures. Rubocop clean.** `/repeats` lists what either of you logged in the last 30 days, deduplicated by food, newest first; tapping one opens a portion screen that defaults to the source's own weight; "Log it" writes the scaled copy onto your own day. Three taps, no typing.

**Item 3 below is not built, and the spec was wrong.** It called for logging onto either person's day from the picker. Built that way and used for an evening, it was immediately the odd one out: the manual form logs to you, the chat's `log_meal` logs to you, and only this screen quietly offered to write onto somebody else's day. Raquel's actual request was *"let me pick from meals Doug already entered and say how much **I** ate"* — pick from anyone's plate, log onto your own. That is what ships.

Writing to another person's day now has exactly one entry point: `copy_to_household_member` in the chat, where you have to name them. One deliberate route beats two, one of which is a button you might hit by accident. The `target_id` parameter is **removed** rather than validated — a parameter that doesn't exist cannot come back wrong in a later refactor.

**Scaling never rounds on write.** The plan's worked example — 360 g at 559 kcal logged as 180 g — stores 279.5 and renders "280" through the existing `calories` helper. That is what stops the macros drifting away from the calories: nothing is rounded before it is summed, so the macro-to-calorie ratio is preserved exactly at every factor (tested at 0.25×, 0.5×, 1.5× and 3×).

**A resized copy rewrites its own assumptions.** "Assumed a pub-sized bowl" stops being true the moment it is halved, so a scaled copy is prefixed with "Portioned to 180g of Doug's entry." The original note is kept rather than dropped — it often carries composition ("no cheese or sour cream") that survives the resize even when the portion doesn't.

**The live preview is verified by hand, not by CI — read this before trying again.** "Show the resulting calories live" only exists in the browser, so nothing server-side can see it. I built system tests for it (headless Chrome via the existing capybara/selenium gems) and then deleted them, because they were not dependable enough to keep: the whole file passed **2 runs in 6**.

The failure is not in the app. Instrumenting the page showed the button in the right place, unobstructed, with `document.elementFromPoint` returning the button itself — and **no `pointerdown` and no `click` event reaching the document at all**. Selenium reports the click as successful and dispatches nothing. Per-test measurements over six runs each: a test that only types (`fill_in`) passed 5/6, a single click after a direct visit 6/6, a chip click 3/6, and a chip click followed by a submit 0/6. A larger viewport helped a little (3/6 → 5/6 on one test) which points at scroll-then-click, but never got the suite to reliable. Not resource exhaustion — one Chrome process, 26 GB free.

So the live preview was checked the honest way: drive it, look at it. Tapping 0.5× on a 360 g / 559 kcal entry sets the field to 180 g and the preview to **280 kcal, 15gP 10gF 25gC** — the plan's worked example, on screen.

**The rule this settles, for every browser-only feature after it: keep the seam thin, and test the server side of it.** This paragraph used to end by saying WP5 (recording) and WP7 (barcode) needed browser tests far more than this screen did, and that neither could be covered any other way. WP7 then shipped and proved the second half wrong. `barcode_controller.js` ends every failure path — no `BarcodeDetector`, no supported formats, camera refused, no camera, camera won't start — at the same `giveUp()`, which hides the video and leaves the typed-number form alone; and that form is a plain server-rendered GET precisely so the fallback does not depend on the thing that just failed. The result is 13 tests in `scans_controller_test.rb` covering the entire feature, with the untestable surface down to three calls: `getUserMedia`, `detector.detect`, `window.location.assign`. That is a phone pointed at a yogurt tub, not a CI rig.

WP5 gets the same treatment, and its fallback is better than WP7's. (Split on 2026-08-22 — the browser-only surface described here is WP5-b's; WP5-a's is smaller still, one `SpeechRecognition` object, and ends in the same composer.) §2 records that the phone keyboard's own dictation already logs meals correctly, for free — so when the record button fails, you are standing in the chat composer that is already built and already tested. The browser-only part of voice is `getUserMedia` → `MediaRecorder` → POST a blob. Everything from the POST onward — the endpoint, the STT call, the vocabulary hint from §6's `foods` query, the handoff to `AiChatTurnJob`, the `source: "voice"` attribution — is ordinary controller-and-service testing, with `Ai::Fake` and Faraday's test adapter as the seams that already exist. Automating the recording itself would mean `--use-fake-device-for-media-stream`, a synthetic clip and faked permission prompts: the same rig that produced the 2-in-6 above.

**So capybara and selenium-webdriver were removed from the Gemfile on 2026-08-20**, along with `image_processing`, `thruster`, `faraday-multipart` and `tzinfo-data` — 16 gems out of the lockfile. Nothing had referenced them since the deleted suite, and the CI system-test job went in `0d8fc56`. If a browser-only feature ever genuinely resists being reduced to a thin seam, `bundle add capybara selenium-webdriver` brings them back — but reach for the seam first.

**Not built, deliberately:** the per-entry "also log for \<name\>" button from §7. The picker covers both directions — after Doug logs dinner it is the newest household entry, so Raquel taps it from `/repeats` — and a second affordance for the same gesture is worth adding only if the picker turns out to be the wrong shape in daily use.

### Original spec for WP6a, kept for the record

1. **A picker over recent household entries**, both people's, most recent first, deduplicated by food. This is the screen Raquel asked for: what got eaten lately, tap one.
2. **Portion control on the way in** — grams if the source had grams, multiplier chips otherwise. Show the resulting calories live as it changes, so the number is confirmed before it's saved, not after.
3. ~~**Log to either person from the same screen.** "For me" / "For \<name\>" rather than a copy that always means *the other one*, so it works the same whichever of you is holding the phone.~~ **Dropped 2026-08-19** — see above. The screen works the same whoever holds the phone because you pick from the whole household and log onto yourself; it does not need to write to anyone else's day to do that.
4. `source: "copied"` and `consumed_at` = now, per §7.
5. **Scaling is the thing to test.** A 360 g entry at 559 kcal logged as 180 g must be 280 kcal, and rounding must not drift the macros away from the calories.

**Done when:** Raquel can log her share of a dinner Doug entered, at her own portion size, in three taps and no typing.

### WP6b — matching ✅ *done 2026-08-19*

**Result: 153 tests, 550 assertions, 0 failures. Rubocop clean.** Verified against the real API: "I had a glass of magic juice" — yesterday's failure — now logs **Magic Juice**, 194 kcal for a 240 ml glass, against the imported row, with the model's own note reading *"used your saved Magic Juice recipe (81 kcal/100g)"*. Our stored figure gives 195 for that volume.

**Two mechanisms, because §7 asks for two different things.** A meal the household has eaten before is offered directly in the chat and logs on one tap with **no model call at all** (`source: "matched"`). Anything that does reach the model is given the household's closest foods and entries in the prompt first, below the cache breakpoint, so the model prefers what we already know over inventing a name.

**Scoring: the greatest of three trigram measures.** Plain `similarity` collapses when a short food name sits inside a sentence — "Magic Juice" against "I had a glass of magic juice" scores 0.41. `word_similarity(name, text)` asks how well the name matches some run of words *inside* the sentence, which is the real question, and scores that pair 1.00. The reverse direction rescues the opposite case, a long stored name only partly spoken ("leftover ikea meatballs"). Best-of-three separated genuine matches (0.45 and up) from unrelated food (0.12 and below) across every pair tested.

**It suggests; it does not log by itself. That is the finding, not a preference.** A correction is made of the same words as the thing it corrects, so it scores alarmingly well: *"make that double chicken"* hits **0.40** against *chicken burrito bowl*, and *"the pasta was bigger than that"* hits **0.35** against *Pasta with tomatoes*. The weakest genuine match measured 0.45. That is the entire margin, and no threshold separates the two cases because similarity is not what distinguishes them — conversational context is. Auto-logging on a threshold would therefore insert a whole extra meal in the middle of a correction, silently, in a calorie tracker. A misfire now costs an ignored card; a miss costs one API call, which is what today already costs. There is a regression test asserting that seven ordinary follow-ups stay under the bar.

**Item 1 below was wrong and is not built.** It called for `Food.match_or_create` to merge rows by trigram similarity. Measured on real names, name-to-name similarity does **not** separate same-dish from different-dish: *"Pasta with tomatoes"* vs *"Burst Cherry Tomato Pasta"* (genuinely the same plate) scores **0.57**, while *"chicken burrito bowl"* vs *"beef burrito bowl"* scores **0.75** and *"porridge with honey"* vs *"porridge with berries"* scores **0.70**. Auto-merging would have quietly folded beef into chicken. Trigram similarity measures spelling, and spelling is a good proxy for "is this name in that sentence" but a bad one for "are these the same food". `match_or_create` stays an exact, case-insensitive match; retrieval stops the duplicates upstream instead, by answering before the model gets to invent a second name.

**Hit rate is instrumented** — every message logs `meal match: hit|miss score= name= query=`, which is the number §17's pg_trgm-vs-pgvector question turns on. The threshold is a constant with the measured margins written next to it, because it was tuned against six real foods and wants revisiting once there are sixty.

**Still open at the time, closed by WP4.4:** a food with nutrition but no entry (an import) could only be a hint, never a one-tap suggestion, because there was no portion to offer. It now has a portion screen and a search box, reached from the picker rather than the chat. It is still not a one-tap *chat* suggestion, and WP4.4 says why that stayed a decision rather than an oversight.

#### The evidence that moved this up the order

**Evidence from 2026-08-18 that raises the stakes here.** `Foods::EasyfitImport` now pulls hand-picked rows out of the old EasyFit Pro export into `foods` (Magic Juice is in: 81.13 kcal/100g, reconciled from the macros because the export's stated calories were 13% adrift). Asked for "a glass of magic juice", the chat **logged 150 kcal of mango juice** and created a second `foods` row — because nothing reads the table, and §9's instruction to infer a plausible dish from a garbled food name turned a known food into a typo. The instruction that makes dictation work is the one that overrode our own data.

**The reconciliation above ran the wrong way, corrected 2026-08-19.** "Reconciled from the macros" was the wrong call: Doug crafted each EasyFit serving to be the portion he actually eats and the calories he believed it cost, so the **stated calories are the anchor and the macros are the softer number** — the reverse of what `EasyfitImport` shipped with. Measured across all 123 rows the two mostly agree (median macro/stated ratio **1.004**, 104 rows within 10%), so this is a tail problem, not a corpus-wide one; Magic Juice just happens to sit in the tail. It is **71.87 kcal/100g**, not 81.13 — the old figure was 12.9% high. The importer now anchors on the stated calories, rescales the P/C/F split in proportion to match, and flags rows past a 10% gap rather than rejecting them, since a disagreement impugns the split and not the calorie figure. **Checked on das after deploying: no EasyFit row has ever been imported to production** — the Magic Juice row is a development one, and all 12 production `foods` rows are chat-created with no nutrition at all. So nothing user-facing was ever wrong, and WP6b's retrieval currently matches names without having macros to offer behind them.

**`Foods::EasyfitImport` was deleted on 2026-08-22.** Everything above is the record of *why* that corpus needed a hand pass before it could be trusted — and the pass happened. The 56 rows it vetted reached production inside `db/seeds/foods.csv` through `Foods::CsvImport`; the class had no second job, and two importers in one namespace is a question every future reader would have had to answer once.

So this package is not only a cost optimisation. Until it lands, imported foods are worse than inert: the app will confidently rename them. Whatever else changes, retrieval has to run *before* the model gets a chance to guess at the name.

1. `Food.match_or_create(name)` using `pg_trgm` similarity, scoped first to the household's last 90 days, then global `foods`. Tune the threshold against real data, not a guess.
2. **Surface matches before inference runs** — "the usual chicken bowl — 780 cal?" is retrieval, not estimation.
3. Instrument the hit rate. It's the number that tells you whether §17's `pg_trgm`-vs-`pgvector` question needs answering at all.

**Done when:** a dinner you've eaten before logs without an API call.

---

## WP4 — Conversational logging, text only ✅ *done 2026-08-18*

**Result: 100 tests, 351 assertions, 0 failures, zero network calls. Rubocop clean.** Verified against the real API, not just the suite: "a bowl of chili and a slice of sourdough with butter" logged as **two** entries from two parallel `log_meal` calls in one turn (420 + 205 kcal, both with stated assumptions), and "actually that chili was a huge bowl, more like double" updated entry #8 in place to 840 kcal rather than creating a second row. Prompt caching fires — `cache_read=1874` on every call, the whole tools+system prefix.

**Two bugs the suite could not have caught, both found on the first real call:**

1. **`caller_` went out on the wire.** Assistant turns are persisted by serializing the response's content blocks. `content.to_json` on the array routes through ActiveSupport's `as_json`, which reads each block's *internal* field names — so a `tool_use` block was stored carrying `caller_` instead of `caller`, and the **next** request 400'd. Only the SDK's own per-object `to_json` maps fields back to their API names. Serializing one block at a time fixes it, and `Ai::FakeClient` now builds its canned responses through the same coercion the real client runs on an HTTP body, so a hand-built block can never again serialize differently from a parsed one.
2. **The model narrated a day total that double-counted the meal it had just logged.** The system prompt carried today's totals *and* the tool returned `day_total`, and it added them — 1,250 against a true 625. Two causes: the volatile block was rebuilt on every loop iteration, so by the second call its "start of this turn" label was false; and the wording invited arithmetic. Now the system prompt is built **once per turn** (which also keeps the cached prefix stable across a turn's requests) and states outright that a tool's `day_total` replaces the figure above, with a worked example. Both turns now quote the tool's number exactly.

The second one is the one to remember: it is a wrong number shown to a person in a calorie tracker, it looked completely plausible, and no test would ever have flagged it. **The suite proves the plumbing; only a real call proves the numbers.**

Four things worth knowing about what got built:

- **`messages.input_source` is a new column.** `last_input_source` had nowhere to read from. It lives on the message rather than the conversation because one thread mixes both — you type a correction to something you dictated — and `meal_entries.source` is copied from it, so WP5 gets voice attribution for free.
- **The user's message is created by the controller, not the job.** §16 shows the job doing it; that renders a second late, after a worker picks the job up. The job owns everything from the first API call onward.
- **`Food.match_or_create` exists and delegates to `find_or_create_by_name`.** The tool handlers already call the matching entry point, so WP6b's trigram work lands in one method body instead of every call site.
- **`Met::Table` is real.** `log_exercise` is in `MealTools::ALL`, so shipping the tool without a handler would have meant the model could call into a hole. It is ~20 activities with a light/moderate/vigorous MET each, falling back to a general value rather than refusing, and defaulting to 75 kg until WP8 puts a weight field on screen.

**Still verbatim-from-§16 and deliberately so:** the copy is unportioned. WP6 changes that, and changing it here would have meant designing WP6's tool schema early.

Design refs: §8, §9, §15, §16, §14.3. **Goal: type "a bowl of chili and a slice of sourdough with butter" and it gets logged.**

Build in this order; each step is independently testable:

1. **`Ai::MealTools`** — §15 verbatim. Pure data, no behavior, no tests needed beyond a schema-shape sanity check.
2. **`Ai::ToolHandlers`** — §16 verbatim. **This is where the tests go.** It's plain Ruby taking a hash and touching the database, so test it directly with no API in the loop: `log_meal` creates an entry and returns the ID; `update_meal` is user-scoped and can't touch the other user's row; `copy_to_household_member` copies and raises when there aren't exactly two users; an exception produces `is_error: true` rather than blowing up the turn.
3. **`Conversation` / `Message`** with `#to_api_messages` (windowed to ~10 turns per §9), `#last_user_text`, `#last_input_source`. `content` is stored as raw Anthropic content blocks and replayed verbatim — resist the urge to normalize it into your own shape; the whole point is that it round-trips.
4. **`Ai::Prompts.meal_logging(user)`** — §9's prompt, plus today's totals injected. **Keep the cacheable prefix byte-stable**: put the `cache_control` breakpoint on the last static system block, and inject the volatile part (totals, current time) *after* it or in the user turn. An interpolated timestamp above the breakpoint silently kills caching, and nothing will tell you.
5. **`AiChatTurnJob`** — §16 verbatim, including `MAX_ITERATIONS = 5`, adaptive thinking, `effort: "low"`, `max_tokens: 8192`. Do not "optimize" by disabling thinking; §8 explains the silent-failure trap in detail.
6. **A fake client for tests.** `Ai.client` should be swappable to an `Ai::FakeClient` returning canned responses — one with a `tool_use` block, one with plain text, one with two tool calls in a single turn (to prove all results go back in **one** user message). This is the invariant most likely to break and the one hardest to notice.
7. **Chat UI + Turbo Streams**: user message appends immediately, typing indicator while the job runs, assistant message and confirmation card stream in, header totals update.

**Done when:** a novel meal logs correctly from the chat, a follow-up correction ("make that double chicken") updates the same entry rather than creating a second one, and the whole suite passes with zero network calls. ✅ all three.

### First real use, 2026-08-18 (evening)

Deployed and used by both of us the same night. Doug logged a cheeseburger, a serving of fries, and a plate of IKEA meatballs; Raquel logged her own meatball plate in her own thread. Four entries, five tool calls, ~9,600 tokens across both conversations — about two cents.

Three things the live run showed that the suite could not:

- **The correction path works conversationally.** *"Modify the the meatballs recipe. I only ate about half a cup of mashed potatoes and maybe a half a cup of broccoli"* produced a single `update_meal` on the existing entry: 950 → 785 kcal, no second row, doubled "the the" absorbed without comment.
- **The day-total fix holds.** 620 → 990 → 1940 → 1775 across the thread, every figure matching the tool's `day_total` exactly — including the *decrease* after the correction, which is the case most likely to tempt the model back into arithmetic.
- **It hedges on its own initiative.** On the big plate: *"I'm flagging it low confidence since portions of mash and gravy swing a lot."* That is §2's argument working without being prompted for that specific dish.

Caching behaves as designed in production: `cache_write=1875` once per conversation, `cache_read=1875` on every call after.

**Deploying it needs one manual step.** `config/credentials.yml.enc` is a Capistrano `linked_file`, so production reads `shared/config/credentials.yml.enc` on das — the repo copy is not what runs. A key added locally has to be copied up before the first deploy that needs it:

```bash
scp config/credentials.yml.enc das:/home/doug/webapps/macrotrack/production/shared/config/credentials.yml.enc
```

das's `master.key` is byte-identical to the local one, so no re-encryption is involved. This applies to every future credential too — the STT key in WP5 will need the same step.

**Watch for:** cost sanity. Each turn logs `ai turn: in=… out=… cache_write=… cache_read=…`. A real two-turn exchange costs about 4,700 tokens all-in. Log `usage` from every response into `messages.token_estimate` from day one. At ~120 parses/month you should see single-digit dollars; if you see more, something is looping.

---

## WP4.4 — Reaching a food nobody has eaten ✅ *done 2026-08-19*

**Result: 239 tests, 837 assertions, 0 failures. Rubocop clean.** Driven on the real dev database, not just asserted: searching *magic* on `/repeats` returns **Magic Juice**, its portion screen defaults to one 227 g serving at **163 kcal**, and 1½ servings logs **340 g / 245 kcal** onto today, rendered unhedged on the day page.

**The gap, found by using the app.** Doug searched the chat for "serving magic juice" and got nothing, then looked for Magic Juice in the repeat picker and found nothing there either. Two different causes, and only the second is a gap in the code:

1. **Production has no imported rows at all.** The chat found nothing because there is nothing to find — see the 2026-08-19 note under WP6b. That is WP4.5-a's job and no screen fixes it. (Closed 2026-08-21: 190 rows.) (Checked in dev, where the row *does* exist, the matcher scores `word_similarity("Magic Juice", "serving magic juice")` at **1.00** — retrieval was never the problem.)
2. **Nothing in the app can surface a `foods` row that has never been eaten.** `RepeatsController#index` draws from `MealEntry.recent_in_household`; it is an *entries* list deduplicated by food, so a row with no entry behind it is unreachable by construction. `Meals::Matcher#best_entry` has the same rule for the same stated reason — a bare foods row has no portion to offer. Foods reach `#hints` and nowhere else, which makes them a line in a prompt and nothing more.

**This was already written down as WP6b's one open item, assigned to WP4.5.** It is split back out and built first, because the two halves of WP4.5 are independent and that ordering was backwards: extraction first produces ~141 rows with no way to look at a single one of them in the app. Phase 2 is scans of handwritten cards where a misread quantity yields confidently wrong macros — reviewing those needs a screen that exists.

**Nothing new was needed to build it.** WP7 already wrote the object: `FoodPortion` is a portion screen for a food with no entry, and WP7.5 gave it servings. The import path refuses a serving basis with no `serving_g`, so any row that claims a serving arrives knowing what one weighs — the ½ / 1 / 1½ / 2 chips work on those with no extra work. (Written expecting a corpus of ~123 EasyFit rows, every one of which states a serving. What landed is 190 rows of which **56** do; the other 134 are costed per-100g and portion in grams, which the same screen already handles.) The form itself is now `shared/_portion_form`, rendered by the scanner and the picker alike, because the question they ask is identical and only the way you arrived differs.

### What changed

- **A food has its own portion screen**, keyed on the food (`/foods/:id`) rather than a barcode or an entry. The scanner's version could only be reached by holding the tub up to the camera again; an imported recipe has neither a barcode nor an entry, so it could be reached by name in the chat and nowhere else.
- **The repeat picker is now "Find a food"**, with a search box. Unsearched, it is exactly what it was — what the household ate in the last 30 days, newest first, which is what Raquel asked for and what actually gets tapped. Searched, it also lists foods nobody has eaten, under a heading that says so.
- **Entries win their food's slot.** A plate somebody really ate beats a serving size off a label, so a food that has been eaten appears once, as the entry, and never twice under two headings.
- **Searching reaches back a year; browsing still stops at 30 days.** The window is what keeps the unsearched list short enough to scan. Someone typing a name has already said which meal they want, and "we ate that in March" is the answer they are after.
- **Entries logged this way are `source: "matched"`**, not `manual` — the numbers came off a row we already had rather than being typed or estimated, so the day page states them instead of hedging them.
- **Foods with no macros are never offered.** Most of the table is still names the chat invented with nothing behind them; there is nothing to put on a portion screen for one of those, so the picker filters them and the URL redirects with a note.

### The search threshold is 0.6, and it was measured

A typed search is a different question from `Meals::Matcher`'s and wants a different rule. That reads a whole sentence and has to keep a correction from being mistaken for a food, which is why it sits at 0.45 and only ever *suggests*. This reads a query somebody deliberately typed, and a wrong row costs a glance.

Measured against the real corpus — ten EasyFit names mistyped the way a phone keyboard mistypes them, each scored against its own row and against the other 122:

| | worst | best |
|---|---:|---:|
| The row the query meant | **0.714** (`magik juice`) | 1.000 |
| The strongest row it did **not** mean | 0.176 | **0.556** (`tofu stw` → *Tofu Fried Rice*) |

So the gap is 0.56 to 0.71 and **0.6 sits in the middle of it**. Worth noting the rows just under the bar are near-misses rather than nonsense: this is trading a little recall for a short list, which is the right trade on a phone.

**`word_similarity` does more of the work than expected**, and the substring clause beside it nearly became decorative. Measured, the trigram already handles the half-typed word (`mag` → 0.75 against *Magic Juice*) and the fragment starting mid-word (`inger Miso So` → 0.85), because it scores against the best-matching run of characters rather than the whole name. `ILIKE` is kept for the one case it is genuinely load-bearing — a query too short for trigrams to say anything about, where a bare `m` scores 0.50 and would otherwise miss — and because it makes the promise unconditional: a run of characters really in the name returns the row, whatever this threshold is tuned to next. It is one more OR against the same GIN index.

### Deliberately not built: a food as a one-tap chat suggestion

`best_entry` could now offer a food, since there is finally a portion to offer. It doesn't, and that is a decision rather than an oversight. WP6b's margin — weakest genuine match 0.45, strongest ordinary follow-up 0.40 — was measured against **six** foods the household had actually eaten. A food match means a name exists in a corpus about to grow to ~141 imports, many of them variations on each other, which is the case the plan already flagged as wanting the threshold revisited. Offering a one-tap card there would insert a whole meal in the middle of a correction. It stays a hint until there is data to say otherwise; the cost is one API call, which is what today already costs.

**Done when:** you can find and log a portion of a food nobody has eaten yet, by name, in three taps and no model call.

---

## WP4.5-a — Bulk import of structured food data ✅ *done 2026-08-21*

**Goal: hand the app a file of foods and have every row land as a `foods` row, so "log a bowl of the lentil soup" hits retrieval instead of a fresh estimate.** Shipped as `Foods::CsvImport` and `rake 'foods:import[path]'`. **190 foods are in production as of 2026-08-21**, which is what closes the hole WP6b and WP4.4 both kept running into: retrieval was matching names with nothing behind them.

**This replaces the old WP4.5, "Recipe import from Drive" (rewritten 2026-08-22).** That package folded two unlike things into one number — a *product feature* (the app accepts structured food data) and a *one-off chore* (Doug's recipe corpus and EasyFit export, cleaned up and merged). They have different done-conditions and different lifespans, so they split into 4.5-a and 4.5-b. The `4.5` prefix stays so the cross-references in WP6b, WP4.4, WP7, WP7.5 and WP5 still resolve.

The **one-off merge does not ship**. Its only surviving output is one file in the supported format, `db/seeds/foods.csv`, imported through the real feature like any user's would be. Provenance is a non-goal: no row records which corpus it came from, because nothing downstream would ever read it.

### The import format

CSV, one row per food, header line required. Column order is free; unknown columns are ignored.

| Column | Required | Meaning |
|---|---|---|
| `name` | yes | Matched case-insensitively against existing rows, so a re-import updates rather than duplicates |
| `basis` | yes | `100g` or `serving` — what the numbers on this row are *per* |
| `calories` | yes | kcal, on the stated basis |
| `protein_g` `carbs_g` `fat_g` | no | grams, on the stated basis |
| `serving_g` | when `basis=serving` | The weight one serving actually is |
| `serving_label` | no | What a human calls that portion — "1 slice", "2 tbsp" |

Five rules, all enforced rather than documented-and-hoped-for:

1. **`basis=serving` requires `serving_g`.** Without a weight the figures can never reach per-100g, and a row that can't be converted isn't a food, it's a note.
2. **`serving_label` requires `serving_g` behind it.** A chip reading "1 bowl" with no weight attached is a lie with a nice font.
3. **A blank macro stays `nil`, never `0`.** Storing zero claims the food has no protein; blank says nobody measured it. Most of this corpus states calories alone, so this is the common case, not the corner.
4. **Density must land in 15–900 kcal/100g.** Same band the app uses everywhere else. Above 900 is arithmetic rather than food; below 15 a weight has swallowed the calories. Here it's a validation *error*, not a silent skip — see below.
5. **A name may appear only once per file.** Upserting by name would otherwise keep whichever row happened to be last, silently.

**The whole file is validated before anything is written; one bad row imports nothing.** This is the decision most worth re-reading later, because the tempting alternative — import the 189 good rows, report the one failure — is worse. The caller is handing over a dataset they believe is clean. A partial import leaves them unable to say what actually landed, and the only recovery is to diff the database against the file they started with. Rejecting the file costs one fix-and-rerun; a partial import costs an audit.

`DRY_RUN=1` writes for real inside a transaction and rolls back, rather than simulating. A rehearsal that takes a different code path can only tell you about itself.

### The one-off merge — local work, deliberately not shipped

Two corpora, cleaned separately and merged offline over 2026-08-21.

**EasyFit export (123 rows).** Doug marked 56 for import in a spreadsheet, as a new `import` column. **The rows marked no were ignored completely** — they are not in the file and were never costed. Six of the 56 were provably broken and got hand-fixed on his ruling: Prosciutto Slice, Swiss Cheese Slice, Popped Corn, Chicken Dark Meat, Chocolate Almonds, Sauce Deuxelles. Three more were accepted unchanged despite a >10% macro gap.

**Drive folder `0B2s-AeGV6GVJN0ZkYkY1LUdPdU0` (143 files).** Pulled with `~/Tools/gdrive`, 0 failures. 95 carried usable text; 36 were transcribed by reading the page image with vision; 12 more were rescued without vision by matching a text twin; 1 (Apple Pie, 2014) is two words and no recipe. Costed against a local table of 287 ingredients — no USDA client exists in the app, so that table is scaffolding, not product.

**Merged output: 190 rows.** 134 are per-100g figures costed from ingredients; 56 carry the serving weight from EasyFit and so can offer a serving chip. All 190 validated clean through the real importer on the first attempt.

### The one insight that unblocked it

The old spec said per-100g macros need a real yield, and treated the ~40 yield-less scans as blocked on weighing the finished dish. **That was wrong, and it was blocking roughly 142 of 143 files.** Per-100g needs a *ratio*, not a weighed dish:

```
kcal_per_100g = total_kcal / (total_raw_g × retention) × 100
```

Yield cancels out. Retention factors for cooking water loss, by detected method: **0.78** roast/bake, **0.88** simmer, **0.85** fry, **1.0** no-cook. Weighing the dish would still be more accurate — but not weighing it is no longer a reason to skip the file.

### Three corrections to the inventory this package used to carry

- **143 files, not ~141**, and **48 needed vision, not ~40**. Nor are they one 2012-07-25 batch: 36 from 2012-07, a second batch of 7 from 2012-11, and strays from 2015, 2017 and 2023.
- **Yield coverage is 59 of 95 text-bearing files — 62%, not "most of the corpus".** The old claim was true of web print-outs specifically and got over-generalised to the Docs.
- **`SeifertFamilyRecipes.docx` is 28 recipes, and 11 of them are typed versions of files sitting in the vision queue as scans.** Splitting it properly took the costed total from 123 to 146. Left unsplit it costed as *one* 390 kcal/100g row, which is the kind of failure that looks like success.

### Calibration against Doug's own figures — the result that matters

Eight recipes exist in both corpora, so the costed density can be checked against the figure Doug crafted himself.

| Recipe | EasyFit | Costed | Ratio |
|---|---:|---:|---:|
| Oatmeal Crepes | 390.8 | 382.4 | 0.98 |
| Chicken Curry Ala Seifert | 129.2 | 166.9 | 1.29 |
| Chicken Cacciatore | 109.1 | 143.8 | 1.32 |
| Spicy Curry Lentil Soup | 67.0 | 107.2 | 1.60 |
| Tortilla Española | 76.7 | 126.9 | 1.65 |
| Steel Cut Oats | 132.3 | 87.8 | 0.66 |
| Portobello Sandwich | 156.4 | 353.2 | 2.26 |
| Fideo | 55.1 | 11.2 | 0.20 |

Median ratio 1.30. Only 2 of 8 within 30%; 2 worse than 2×.

**Neither corpus is reliable at the row level without a human glance, and that is the finding WP4.5-b has to be designed around.** The two 2× misses are not arithmetic errors — they are source-completeness failures. The "Sandwich Portabello" Doc contains only a mayo dressing, not the sandwich. Fideo leaves its pasta and tofu unquantified, so costing silently omitted the calorie-dense half.

And where the two disagree it is genuinely not obvious which is right. **EasyFit's serving weights are unmeasured dropdown defaults** — 20 of 56 sit at exactly 8 oz, and only Corn Tortilla (1.45 oz) breaks the round-ounce pattern. That reverses the assumption recorded under WP7.5: the stated *calories* are the number Doug believed, but the *weight* dividing them is the soft one. His Steel Cut Oats at 132 is probably worse than the costed 88.

Worth knowing before trusting any embedded nutrition table: **Doug's own Chicken Curry recipe lists coconut cream at 110 kcal for a 14.5 oz can**, off by roughly 12×. Correcting it moves his own total from 123 to ~176 — past the 167 that costing produced independently. A stated nutrition panel is a data source, not a free pass.

### In production

`rake 'foods:import[db/seeds/foods.csv]'` on das, 2026-08-21: **190 created, 0 updated.** Zero name collisions with the 29 rows already there, 26 of which are chat-created names carrying no nutrition at all. Production now holds **219 foods, 193 loggable, 59 with a serving chip**.

### Seven rows were corrected after they were already live (2026-08-22)

Not a footnote — this is the strongest evidence 4.5-b has, so read it as a finding rather than a changelog.

| Row | Was | Now | Found by |
|---|---|---|---|
| `Pancakes Alton Brown` | 28.4 g · 43 kcal · 151/100g | **`Pancakes`**, 36 g · 61 kcal · **170**/100g | Doug recalling the recipe he *currently* cooks |
| `Sauce Deuxelles` | 130/100g, macros rescaled from EasyFit | **95.5**/100g, macros re-derived from the recipe | the actual recipe surfacing in `Fondu Sauces.pdf` |
| `Scone` | 113 g · 44/100g | 13 g · **385**/100g — a mini scone | naming the portion |
| `English Muffin` | 113 g · 70 kcal · 62/100g | 57 g · 140 kcal · **246**/100g | figures matched *half* a muffin |
| `Egg Noodles` | 340 g · 59/100g | 150 g cooked · **133**/100g | figures were the **dry** panel |
| `Steel Cut Oats Cooked` | 113 g · 132/100g | 160 g cooked · **94**/100g | figures were the **dry** panel |
| `Lebkuchen` | 57 g · 194/100g | 30 g · **367**/100g | naming the portion |

**Renaming the serving labels is what found the last five.** The 38 ounce labels were cosmetic — the form rendered `1 serving = 227g (8 oz)`, a parenthetical that only restated the weight. Replacing each with a portion name ("1 slice", "1 large bowl", "2 slices") forced a claim about what the portion *is*, and five rows did not survive the claim. **A label that names something is checkable in a way a unit conversion never is**, which is an argument for requiring one rather than treating it as decoration.

In all five the calories and macros were internally consistent and correct; only the gram weight was wrong. That is the EasyFit dropdown-default finding holding at a sixth point of evidence.

The pancake row is the instructive one. Its name attributed the recipe to Alton Brown; nothing in either corpus does. The file it matched — "A Good Pancake Recipe", a 2005 web print-out, not the handwritten card I claimed it was — agrees with Doug's own figure on density within 5%, the closest agreement of any overlapping pair in the corpus. **And it was still wrong**, because he has since swapped 1¼ c flour for ¾ c flour plus ½ c almond flour, and gets 18 pancakes out of the batter rather than 12–14. Neither corpus knew that. No amount of better parsing would have found it.

**So the rule for 4.5-b is that human review is not a safety net over bad extraction — it is where a whole class of correct-looking answers gets fixed.** A recipe can be faithfully transcribed, correctly costed, and corroborated by a second source, and still not be the food that gets eaten. That argues for a review screen that shows the *ingredient breakdown* and lets a quantity be edited, rather than one that shows a finished per-100g figure and asks for a yes or no.

**Done when:** ✅ you can log a portion of a recipe you cooked by naming it, and the macros come from the recipe rather than from a fresh guess.

### Deliberately not built

- **No `Recipe` model, no ingredient rows.** A recipe is one `foods` row with per-100g macros. `foods` is already per-100g and `meal_entries.quantity_grams` is grams, so a portion is just a weight — no schema change, and WP6b's trigram matching picks it up for free. An ingredient model only earns its keep if you want to scale recipes up and down; don't build it on spec.
- **No JSON format.** CSV, because the file gets edited in a spreadsheet by a human before it is trusted, and that is the whole point of the review step.
- **No provenance column.** Explicitly ruled out. Nothing reads it.

---

## WP4.5-b — Importing one recipe at a time *(target: one evening once scoped; not started)*

**Goal: going forward, add a single new recipe without a spreadsheet and without a merge.** Bulk is done and won't recur — 4.5-a was the backlog. This is the steady state.

**Its requirements come from 4.5-a's grunt work**, which is the reason that work was worth doing by hand: 61 edge cases catalogued **on real data, not hypothesised**. The full catalogue lives in the session notes; the decision it forces is which ones to code for.

### Code for these — they are common and they are silent when they go wrong

| Case | Evidence |
|---|---|
| **Unquantified ingredients must halt, never be dropped** | Fideo names "Tiny pasta" and "Tofu, cubed" with no amount, costed to 11 kcal/100g — a 5× under-count with nothing flagging it. 20 of 117 recipes had this. **The single most dangerous case in the corpus.** |
| Dual metric/imperial with no space | `400g/14 oz canned crushed tomato` parsed as 400 *tomatoes* — 49,200 g. Chicken Cacciatore went 25 → 144 kcal/100g on this one fix. |
| A weight in parentheses overrides a count | "4 chicken thighs (1 kg / 2 lb)" is 1 kg, not 4 × a guessed thigh. |
| Leading list numbers read as quantities | "7. 1 sliced large white cooking onion" → **7 onions**. The same recipe costed 170 vs 68 in its two copies. |
| Cup weights by ingredient class | A flat 240 g/cup (water) applies to 72 of 287 entries wrongly; "5 cups diced chicken" came out 71% high. Solids default 140, generic 150. |
| Discarded ingredients | Shrimp Cocktail's brine, Norinj Pilau's three changes of boiling water. Costing them is pure invention. |
| Method steps and nutrition panels leaking into the ingredient block | Filtering lifted the match rate 83% → 92%. Panels are the dangerous half: numbers beside the word "protein" match and inject calories. |
| The source states its own nutrition | Banana-Rum Souffle gives "Calories 231" per serving. Skip costing entirely. |
| **A nutrition panel states *dry* weight while the eater logs it cooked** | Found 2026-08-22, and it had gone to production undetected. Egg Noodles carried the 2 oz-dry panel against a 340 g cooked serving (59 kcal/100g, should be 133); Steel Cut Oats carried the ¼ cup-dry panel against 113 g (132, should be 94). Note it lands in **both directions** depending on whether the guessed weight beats the true cooked one, so a plausibility band never catches it. Pasta, rice, grains, pulses and oats all state dry. |
| The source states a serving *weight* | "10 lava cakes (4 oz servings)" — rarer and better than a yield count. |
| Retention + the ratio formula | See 4.5-a. This is what makes a yield-less recipe costable. |
| The 15–900 plausibility band | It is the only thing that caught the corrupt Berry Bundt Cake, at 909. |

### Flag for a human — do not try to resolve automatically

Coverage below 80% of ingredient lines; **any** unquantified ingredient; handwritten overrides, strikethroughs and caret insertions on a scan; and the two cases that cost out *plausibly* while being wrong:

- **A file containing only one component of the dish it names.** "Sandwich Portabello" is the dressing alone. Nothing about the output looks suspicious.
- **A text twin that is worse than the scan.** The rescue logic assumed a typed Doc supersedes a 2012 scan. For Berry Bundt Cake the reverse held — the Doc is a corrupt OCR dump of the clipping (`125 cups sugar` for 1⅔, `22 sticks butter` for 2½, `TY2E2h cups flour`). It even states a yield, so every heuristic classed it "costable unattended".

### Out of scope — 4.5-b is explicitly one recipe at a time

Compilation files, cookbook pages holding 2–4 recipes, recipes defined by reference ("make the dough for Russian Teacakes above, omitting nuts"), and variants that aren't separate recipes. These are bulk problems and bulk is finished. If one arrives, split it by hand and import the parts.

Also a human call, not a code path: **not everything is a dish.** Bourbon Sauce, Thai Curry Peanut Sauce, dry rubs, spice mixes, Horchata, Brandy Alexanders want per-tablespoon macros or exclusion, not a serving size.

### The USDA question, measured rather than guessed

Of 238 unmatched ingredient lines in the one-off, the large majority were **near-misses on entries already in the local table** ("shaved Parmesan" vs "parmesan cheese", "EVOO", "vegetable broth") or method steps leaking in — not missing nutrition data. USDA would have needed the same alias layer and adds a verification risk of its own: *Butter, whipped* against *Butter, salted* is a 20% error with nothing to flag it. **It was not worth it for the one-off.**

**It is worth it here.** `Food::SOURCES` already carries a `usda` slot, unused. An ongoing import that costs one recipe at a time can afford a real lookup and a moment of human confirmation per ingredient, which is exactly what the one-off could not.

### Open before this starts

1. **What is the input?** A file is 4.5-a's answer and it is the wrong one here. In practice a new recipe arrives as a URL, a photo of a card, or text pasted from a message. Pick one to build first — the evidence above says the URL case is by far the cleanest, and the photo case is the one already proven to work via vision.
2. **Where does the review happen?** WP4.4's food screen shows a row and portions it, but nothing shows a *proposed* row with its ingredient breakdown and lets you correct a quantity before it is saved. That screen is most of this package.

**Done when:** you can point the app at one new recipe, see what it thinks the ingredients and per-100g figures are, correct it, and save it — without touching a spreadsheet.

---

## WP7 — Barcode ✅ *done 2026-08-19*

**Moved ahead of WP4.5 on 2026-08-19**, for the third application of the same rule that moved WP6a and then WP7 itself: one evening against WP4.5's several sittings, and WP4.5 had quietly grown a portion screen for ~141 imports since it was written. The two are independent — WP4.5's only stated dependency is WP4, which was already done — so nothing was blocked either way.

**What shipped.** `Foods::OpenFoodFacts` (barcode → `foods` row, no key, no account), `FoodPortion` (per-100g → an entry of a given weight), `ScansController` with three screens, and a `barcode` Stimulus controller driving `BarcodeDetector`. **37 new tests; 187 suite-wide, 0 failures, rubocop clean.**

Three things worth recording:

- **`FoodPortion` is a sibling of `MealPortion`, not a reuse of it.** `MealPortion` scales one *entry* onto another person's day and needs a plate someone already ate; a scan has a density and a tub, with no "what he had" to take half of. They share arithmetic shape deliberately, so the existing `portion` Stimulus controller drives both screens with no branching — pass 100 as the reference grams and the per-100g figures as the base. **This is the object WP4.5's portion screen wants**, which closes WP6b's still-open item: an imported food can now be offered a portion.
- **The manual fallback saves the barcode.** A product OpenFoodFacts doesn't have is entered once, against that number, so the next scan of the same tub — by either phone — resolves offline. Without that, a coverage gap would be a permanent dead end rather than a one-time cost.
- **The typed-number form is a plain server-rendered GET**, not JS-intercepted. It is the fallback for a browser without `BarcodeDetector` or with the camera refused, so routing it through JS would make the fallback depend on the thing that just failed.

**Not covered by tests, and it can't be:** the camera path itself — `BarcodeDetector`, `getUserMedia`, the detect loop. Browser-only, and validated by hand. This is the package that settled the thin-seam rule in WP7.5 above: because every failure in the detect loop lands on the server-rendered typed form, the untestable surface is three calls wide. Everything server-side of the detection — lookup, mapping, kJ fallback, the miss branches, portion maths, adoption — is covered, in 13 tests.

*Verified on Doug's phone, 2026-08-19: a snack scanned in production off a real package.* UPC-A `049900342643` resolved through OpenFoodFacts — not the adopt fallback — to **Knudsen cottage cheese, 93.22 kcal/100g, P9.32 C5.08 F4.24**, logged as 115g / 107.2 kcal with `estimated? == false` and no confidence badge, which is the point: a label is read, so it is not hedged on screen. The barcode is stored against the row, so the next scan of that tub from either phone never leaves the building.

Two things that only showed up in real use:

- **It is the first production `foods` row carrying any nutrition.** The other twelve are chat-created names with nil macros, so WP6b's retrieval has been matching names with nothing behind them. The barcode path is what started closing that, ahead of WP4.5.
- **The portion was typed, not tapped** — 115g is not one of `FoodPortion::PRESETS` (30/50/100/150/200). One data point, but if that keeps happening the presets are the wrong numbers for packaged food, where a serving is whatever the tub says. Worth watching before changing anything.

**The original case for building it, from 2026-08-17.** Keeps its number so existing references still resolve; only the build order changed. The reason is §6's own principle — prefer ground truth wherever it exists. A packaged product like "a Oui black cherry yogurt, 5 oz" is a label to *read*, not a description to infer from: scanning it is exact and free, while an AI estimate of the same words is a guess that can be off by 20%. It's also one evening's work against voice's two, and it makes every packaged snack accurate before the harder paths land.

Design refs: §7 path 2, §14.6. `BarcodeDetector` (native in Chrome on Android, on-device, free) → OpenFoodFacts lookup → `foods` row with `source: "openfoodfacts"`. Ground truth, no inference. Include a manual-entry fallback for the products OpenFoodFacts doesn't have — it'll be more of them than you expect.

**`BarcodeDetector` is Chrome-on-Android only** — it does not exist in Safari. Both phones in this household are Android (Pixel 7a; confirmed 2026-08-17, re-confirmed 2026-08-22), so **no JS fallback is needed**. Worth remembering only if the app ever reaches an iPhone, where the scan button would otherwise fail silently.

---

## WP7.5 — Servings ✅ *done 2026-08-19*

**Added 2026-08-19, from one line of real evidence.** The first production scan logged 115g of cottage cheese, typed into the grams field rather than tapped from a preset. The write-up guessed the presets were wrong. They weren't: OpenFoodFacts states `serving_quantity: 115` and `serving_size: "0.5 cup (115 g)"` for that product, so Doug was entering **one serving** and the app had no idea what a serving was.

**`foods` gains `serving_g` and `serving_label`, both nullable.** Grams stay canonical — everything resolves to grams before scaling, and grams are what land on `meal_entries.quantity_grams`. Servings are an *input* unit, offered only when the food knows what one weighs.

**The real reason this is worth a migration is that it makes the per-100g conversion reversible.** Source data that is stated *per serving* — the EasyFit export, essentially every nutrition label — had to be divided by a weight to be stored, and the original figure could not be recovered afterwards. That lossiness is what made the EasyFit trust question feel like a one-way door: choosing which half to believe was irreversible. It isn't any more. `Foods::CsvImport` keeps the divisor, and there is a test asserting Doug's own stated 163 kcal comes back out of the stored row. (That test first landed on `EasyfitImport`, which was deleted 2026-08-22 once its corpus was imported.)

Where servings come from, in order of how much they can be trusted:

| Source | Field | Notes |
|---|---|---|
| OpenFoodFacts | `serving_quantity` / `serving_size` | Off the label. Free, and already in the response — it only ever needed asking for |
| EasyFit export | `serving_g` / `serving_oz` | The portion Doug crafted, which is the whole reason that corpus is worth importing — **but see WP4.5-a: measured across all 56 imported rows these are round-ounce dropdown defaults, so the calories are the crafted number and the weight is the soft one** |
| Manual adopt form | typed | Optional; the screen says so |
| Anything else | — | Stays in grams, exactly as before |

**The screen adapts rather than branching.** With a serving weight, the default portion is one serving and the chips read ½ / 1 / 1½ / 2 servings; without one, it falls back to the 30/50/100/150/200g presets. `FoodPortion` hands the view a `reference_grams` and the figures at that reference, so the existing `portion` Stimulus controller drives both cases with no JS change — the same trick that let it drive WP6a's screen and WP7's.

**One wrinkle worth knowing about:** `OpenFoodFacts.find` answers from our own table once a barcode is stored, which is the point of storing it — so re-scanning a product saved before this migration will *never* pick up its serving. `rake foods:backfill_servings` asks upstream again for exactly those rows.

**204 tests, 0 failures, rubocop clean.**

**Still in grams, deliberately:** the chat path. `log_meal`'s tool schema takes grams, and teaching the model to speak servings is a schema change plus a prompt change plus a new way for a tool call to be wrong. Worth doing only if it turns out to be missed.

---

## WP5 — Voice *(split 2026-08-22: 5-a next, 5-b unscheduled)*

Design refs: §6, §14.4. **Goal: tap, ramble, done.**

### The case for this package narrowed on 2026-08-18 and split on 2026-08-22 — read this before starting

All four of the first night's entries were dictated into the chat field with the phone keyboard's own mic, and every one came through clean. Gboard transcribed **"Ikea meatballs", "mashed potatoes", "gravy", "roasted broccoli", "mayo, mustard and ketchup"** correctly — precisely the food nouns §6 worried about and specified Deepgram's Keyterm Prompting to solve. It also handled a false start (*"Meatballs I ate six Ikea meatballs half a cup of…"*) that the model absorbed without comment, which is §9's transcript paragraph earning its place.

So speech already works, at zero cost and zero engineering, and those entries are stamped `source: "text"` because as far as the app is concerned they were typed. **The header on this package used to read "the one you actually want." That is no longer the honest framing.** What WP5 still buys, stated plainly:

1. **One tap instead of summoning a keyboard**, which is the actual friction when your hands are busy.
2. **Hands-free while cooking** — dictation still needs you to tap into a text field first.
3. **Vocabulary biasing that improves as `foods` grows.** This is the only one keyboard dictation can never match, and it's also the one with the least evidence behind it so far: n=4, all common foods. It will matter more for the WP4.5-a recipe names than it does for a cheeseburger — and as of 2026-08-21 there are 190 of them in production, so this is finally testable rather than hypothetical.
4. **Keeping the audio** (§6), which is genuinely invaluable while tuning and is simply not available through the keyboard.

**The split follows from that list.** 1 and 2 are the two with evidence behind them, and neither needs a server, a provider, or a byte of audio to leave the phone — the platform's own recognizer does both. 3 and 4 are the speculative pair, and they are what the entire cost of this package buys: the provider account, the `Stt::*` seam, `faraday-multipart` back in the Gemfile, Active Storage blobs to back up forever, and the §2 bake-off, which is *genuinely* blocking rather than nice-to-have. Paying that up front for two maybes, when the cheap half can be in your hand in an evening and will tell you whether the expensive half is needed, is the wrong order.

So: **5-a ships now, 5-b waits for evidence from 5-a.** This is the same bar WP11 sets — revisit after real use — applied to a package that was about to be built on a hunch.

**Two consequences for the bake-off in §2.** It moves into 5-b, and it gains a second baseline: keyboard dictation *and* the platform recognizer are now both free incumbents, and a paid provider has to be *visibly* better than the better of the two. The clip should be a hard one: a recipe name, a mumble, a self-correction, background kitchen noise. Four clean sentences from a quiet room will not separate the candidates.

### WP5-a — One tap into the platform's own recognizer ✅ *done 2026-08-22*

**Result: 261 tests + 10 JavaScript tests, 0 failures, rubocop and brakeman clean.** Logged by voice from the kitchen in one tap, and the entry says `voice`. It took four fixes after the first deploy, and every one of them was found by a person with a phone rather than by anything that could have run in CI — which is the argument this package's own testing note makes, so it is worth setting down what actually happened.

**Four bugs, in the order they were found.**

1. **The transcript repeated itself, twice.** Chrome on Android does not report a sentence once. It reports it over and over, each reading one word longer — "I'm", "I'm going to", "I'm going to have" — and it does that *both* across events and within a single `results` array. The first fix caught only the first half and shipped `"two two small two small figs"`, which the production log preserved verbatim in the matcher's miss line. The rule is not "don't append twice": a reading that extends the one before it **replaces** it, because they are two readings of the same words. Readings condense within their own session and only then join, so "and" followed by "and toast" is one utterance growing while "two eggs" before it is not.
2. **A JavaScript deploy never reached the phone.** `stylesheet_link_tag` carries `data-turbo-track="reload"` and nothing `javascript_importmap_tags` renders does, so an app open since before a deploy keeps the modules it booted with — Turbo swaps the body and never re-imports one. The fix that was live on the server for seven minutes did nothing until the app was reloaded by hand. A tracked `<meta>` carrying the importmap digest, which moves when any pinned module does, lets Turbo force the load itself.
3. **Deleting the entry you just logged was a 500.** `conversations.last_meal_entry_id` carried a foreign key with no `ON DELETE`, and the entry it pointed at is by definition the one just logged. See below — the column is gone.
4. **The assistant argued about logging the same meal twice.** First because the transcript still showed it logging the figs and nothing recorded the delete; the volatile block now states the day's entries as the database has them, with their ids, and says the list beats the transcript. Then — because that made duplicates visible — it started asking "another repeat, or genuinely a third pair of figs?", which is a question that changes no estimate and costs a turn to ask for what was just asked for. The user is the authority on what they ate; that rule now sits in the cached block next to the rule about which questions are worth asking.

**`conversations.last_meal_entry_id` is deleted** (migration `20260822180000`). §16 of the design doc gives it, and nothing ever read it: corrections reach `update_meal` through the `meal_entry_id` in the tool result, and the day's log now reaches the model through the prompt. It was a foreign key earning nothing and costing a 500. The migration's `down` puts it back with the nullifying key it should have had, if a reader ever wants it.

**The JavaScript is under test now, and that is new for this repo.** The assembly logic lives in `app/javascript/lib/transcript.js`, imported through the importmap exactly as it ships, and `bin/rails test:js` runs `node --test` over `test/javascript/` — no dependency to install, nothing to build, and no `package.json`, so this stays a Rails app that happens to have some JavaScript. `bin/ci` and the GitHub workflow run it alongside the Ruby suite. Bug 1 was pure logic reachable only through a microphone; it is now seven cases including the literal string production logged.

**What shipped, against the plan below:** all seven steps, unchanged in shape. The one addition is bug 4's half of the prompt, which was not foreseen because it is not a voice problem — it is a chat problem that voice was simply the first to hit.

Small, because WP4 already built everything downstream of a transcript and left it unused: `Message::INPUT_SOURCES` is already `%w[ text voice ]`, `MealEntry::SOURCES` already contains `voice`, `Ai::ToolHandlers` already stamps entries from `conversation.last_input_source`, and `Ai::Prompts::INSTRUCTIONS` already opens by telling the model to expect a transcript with filler and self-correction. What is missing is the thing that produces the transcript.

1. **Both phones are Chrome on Android** — Pixel 7a, confirmed 2026-08-22, same fact WP7 leans on for `BarcodeDetector`. That is the platform where `webkitSpeechRecognition` is best supported, including from an installed PWA, so this package is not the coin-flip an earlier draft of this line claimed: it was written on the mistaken belief that one of the phones was an iPhone, which is where standalone-PWA recognition genuinely does misbehave. **Confirm it from the home-screen icon anyway** — the first tap is the spike, because every failure path below says out loud what went wrong instead of doing nothing. Worth remembering only if the app ever reaches an iPhone, where this button would need re-testing before it could be trusted.
2. **One `dictation` Stimulus controller**, mounted twice. Click starts recognition; interim results stream into a text field so you can watch it hear you; end-of-speech submits the form. The click has to be the gesture the browser sees, which is why each button listens *where it was tapped* rather than navigating to the chat screen and starting there.
3. **Mount one: the chat composer.** A mic beside Send, for when you are already in the conversation.
4. **Mount two: the Add screen**, as the first path, above "Log by chat" — it wraps a hidden form posting to the existing `chat_messages_path`. One tap from Add to a submitted meal, and no new endpoint exists.
5. **`ChatMessagesController#create` accepts `input_source`**, whitelisted to the two legal values, defaulting to text. This is what finally stamps a dictated meal `source: "voice"` — the complaint at the top of this package, unaddressed since 18 August.
6. **The live interim transcript supersedes §6's staged-feedback table.** That table exists to convert a five-second server round trip into a conversation; on-device recognition has no round trip, so the words appear as you say them and the staging has nothing left to hide. Don't build it.
7. **No audio is kept, and that is the deliberate loss.** §6 is right that the recording is invaluable while tuning. What survives is the transcript, as `raw_input` on the entry, which is most of that value. Wanting the audio back is evidence for 5-b, and it is exactly the kind worth waiting for rather than guessing at.

**How this gets tested** — the thin-seam rule, same as WP7.5 and WP7. Step 5 is an ordinary controller test. Steps 2–4 are browser-only and get driven by hand, on both phones, from the home-screen icon. What keeps that safe is the property WP5 always had: failing to record leaves you in the chat composer, which is already covered.

**Done when:** ✅ you have logged dinner from the kitchen, with wet hands, in one tap — and the entry says `voice`.

### WP5-b — Self-hosted STT, and keeping the audio ✅ *done 2026-08-22*

**Result: 270 tests + 7 JavaScript tests, 0 failures, rubocop and brakeman clean.** Not a week after 5-a, but the same afternoon: the second of its three triggers fired outright. The browser's recogniser could not be made to hear a sentence with a pause in it, so 5-b stopped being optional and became the only route.

**It is not hosted.** §2 settled on Deepgram Nova-3 and the bill would have been 32 cents a month, so cost was never the obstacle — but self-hosting turned out to cost less than that in every sense, including effort. `cmake` installs into `~/opt` as a userspace binary, whisper.cpp decodes audio itself through miniaudio, and the browser converts to the 16 kHz mono wav whisper reads. **No signup, no card, no third party holding the audio, and — the surprise — no `sudo` anywhere.** das has no ffmpeg and needs none. §6's one-method interface is built as specified, so a hosted provider still drops in behind it if that ever changes.

**The bake-off, run against whisper.cpp instead of four providers.** One 21-second clip, the hard case §2 asks for — a recipe name from our own corpus, a self-correction, spoken portions, a cooking fat. `tiny.en` 2.2s, `base.en` 3.9s, `small.en` 12.0s, and all three got every word. That made `base.en` look obvious.

**The first real recording said otherwise, and that is the finding worth keeping.** Through the app, `base.en` heard *"ITA meatballs"* for IKEA. The obvious fix — feeding the `foods` table in as whisper's initial prompt, which is exactly the vocabulary biasing §6 designed — **made it worse**: it did not recover the name, and it silently dropped *"about 10 of them"*. A wrong count is a wrong calorie figure; a wrong name is something the model repairs from context and the hints block is built to catch. So there is no prompt, and `Stt::Whisper` says why, so nobody adds one back on the reasoning that looked sound in the morning.

`small.en`, no prompt, gets every word. Greedy decoding and flash attention then took it from 11.8s to about 8s with byte-identical transcripts; quantisation was the obvious thing to try first and did nothing, because on two cores this is compute-bound rather than memory-bound.

**§6's keep-the-audio rule paid for itself within the hour.** None of the paragraph above could have been diagnosed without the recording still being on disk — "the model heard ITA" would have been a guess about capture quality or model size, and the guess would have been the prompt, which would have made it quietly worse.

**Two fixtures, both permanent:** `ramble.mp3`, made for the bake-off, and `meatballs.wav`, which is somebody logging their dinner through the real pipeline and is the case that separates the two models.

**What it costs.** About eight seconds of "Transcribing…" after you press Done, against the browser recogniser's nothing. §1 is why that is the right side of the line: you press Done and put the phone down, so it is elapsed time rather than the hands-and-attention time this app is measured on. Transcription runs inline rather than in a job — it is eight seconds of a Puma thread, but the transcript is the thing being waited for, and a job would mean a second broadcast, a second failure path and a spinner that cannot say which half it is waiting on. Revisit if two people ever record at the same moment.

**Still open, and deliberately not fixed here:** `script/backup_production_db.sh` is a `pg_dump` and the recordings live in `shared/storage`, so the audio is not backed up. That is WP3's file, and roughly 700KB a recording.

**Done when:** ✅ you've logged dinner by voice, from the kitchen, with wet hands, while the screen locked — and three weeks later you can still hear what you said.

---

### What 5-b was going to be, kept for the record

It stayed on the shelf pending a week of real use and any one of these:

- **Recipe names come back mangled** often enough to count. 190 of them in production, so this is measurable rather than hypothetical — and it is claim 3 above finally facing evidence.
- **The recognizer won't run** in the standalone PWA on one of the two phones, which turns 5-b from optional into the only route.
- **You want the audio back** for tuning, which is claim 4 facing the same test.

Then it is the original build:

1. **`Stt::Client`** with the one-method interface from §6, plus `Stt::Hosted` and `Stt::Fake`. Faraday multipart for the upload — `bundle add faraday-multipart` first, it was removed on 2026-08-20 as an unused dependency and this package is what brings it back.
2. **Run the bake-off first, before writing any UI.** §17 asks for it and it is blocking: one real 20-second clip of one of you rambling about dinner, run through two or three providers *and* both free incumbents, picked on **food-noun accuracy**, not latency. Save the clip in `test/fixtures/files/` — it becomes your regression fixture forever. §2 settles on Deepgram Nova-3 as the starting point; that is a shortlist, not a commitment.
3. **`POST /voice_entries`**: accepts the blob, attaches it via Active Storage (**keep the audio** — that is the point of this half), transcribes with the vocabulary hint from §6's `foods` query, then hands off to `AiChatTurnJob` with `source: "voice"`.
4. **Recording Stimulus controller**: `getUserMedia` + `MediaRecorder` (`audio/webm;codecs=opus`). **Tap to start, tap to stop.** Live waveform + elapsed timer.
5. **Request a screen wake lock while recording** (`navigator.wakeLock.request("screen")`, released on stop). §6 flags screen-lock-mid-utterance as the most likely place the PWA behaves worse than native — this is the mitigation, and it's four lines. Test it on both phones deliberately: start recording, let the screen go dark, keep talking.
6. **Stage the feedback exactly as §6's table specifies** — here it earns its place, because here there really is a five-second wait to hide. The transcript landing at ~2s as your own chat message is the load-bearing detail. Don't collapse it into one spinner.
7. **Keep the transcript visible** under the parsed result permanently.

**How this gets tested** — steps 1, 3 and 6 are the server side and get ordinary controller and service tests: `Stt::Fake` and Faraday's test adapter give you the seams without a network call, and the bake-off clip from step 2 is the fixture. Steps 4, 5 and the waveform are browser-only and get validated by hand — the wake-lock case has to be driven physically, and no rig would have caught it anyway.

*(That list is what shipped, with §6's staged feedback and the wake lock intact; only the provider changed.)*

---

## WP8 — Weight + trends *(target: one evening)*

Design refs: §11, §12 UI framing, §14.7. Weight is a number field and a button; ship it early because §12 needs history before it can do anything. Trends tab: weekly average intake, both users' weight on one chart, 7-day rolling average rather than raw dailies. Say plainly on this screen that daily numbers are approximate and the trend is the signal — that's §2's framing finding its home in the UI.

---

## WP9 — Calibration *(target: one evening, later)*

Design refs: §12, §14.8. Weekly job per user: fit the weight trend, solve for `estimated_tdee`, derive `logging_bias_factor`, nudge `daily_calorie_target`. Two things to get right:

- **The "not enough data yet" state** (§17's fourth open question). Fewer than ~14 weight entries in the window → show that honestly, don't emit a garbage TDEE. A wrong TDEE presented confidently is worse than no TDEE.
- **The manual override** on a settings screen. §12 is right that this is the luxury of n=2, and it means the automated fit only has to be roughly right.

---

## WP10 — CSV export *(target: 30 minutes)*

Design refs: §13. One button per user, all entries. It's an exit hatch, and it's also the fastest way to poke at your own data in a spreadsheet when a number looks wrong.

---

## WP11 — Only if actually missed

Photo identification (scoped to *identification*, never unattended macro estimation — §7). Nutrition-label OCR. `whisper.cpp` self-hosting, if the third-party dependency bothers you (not the $0.45/month). The Hotwire Native Android shell, if living without Health Connect turns out to be annoying.

Nothing in this package is on the critical path. Revisit only after a month of real use.

---

## Cross-cutting notes

**Testing.** Minitest and fixtures, matching house style. The rule that matters: **no test hits the Anthropic or STT API.** `Ai::FakeClient` and `Stt::Fake`, injected via `Ai.client` / `Stt.provider`. The genuinely valuable tests are the timezone boundary in `day_totals`, the tool dispatcher's four handlers, and the "two tool calls in one turn come back in one user message" invariant.

**Credentials.** One Anthropic key, one STT key, one Postgres password, in `config/credentials/production.yml.enc`. No per-user keys, no `ai_credentials` table. The production key file is a Capistrano `linked_file` — if you forget it, the app boots and then fails on the first API call, which is a confusing way to find out.

**`/up` healthcheck + uptime ping** (§13). Rails 8 generates `/up`. Point something at it. You want to know it's down before you're standing in a restaurant discovering it.

**Runaway-cost guardrail.** `MAX_ITERATIONS = 5` caps a single turn, but nothing caps a loop that re-enqueues. Log per-turn token usage from WP4 onward and glance at the Anthropic console during the first week. Cheap insurance on an app with no quotas by design.

---

## Sequencing at a glance

```
WP1 skeleton+auth+manual ──▶ WP2 deploy+PWA ──▶ WP3 backups
                                   │
                              [use it for a few days]
                                   │
                                   ▼
                     WP6a pick + portion   (no AI, biggest win/hour)
                                   │
                                   ▼
                            WP4 chat+tool loop
                                   │
                                   ▼
                     WP6b repeat-meal matching   (moved up 2026-08-19 — nothing
                                   │              read the foods table, so imports
                                   │              were worse than useless)
                                   ▼
                    WP7 barcode ──▶ WP4.4 reach a food ──▶ WP4.5-a bulk import ✅
                            │       (split out of WP4.5 2026-08-19:            │
                            │        141 imports need a screen to be           ▼
                            │        checked on before they exist)      WP5-a VOICE ✅ ◀── ergonomics,
                            │                                             one tap,           not capability
                            │                                             no server
                            │                                                 │
                            │                                                 ▼
                            │                                           WP5-b self-hosted ✅ ◀── whisper.cpp
                            │                                           STT + the audio         on das; 5-a
                            │                                                                   proved it short
                            │
                            │                     WP4.5-b one recipe at a time ──▶ unscheduled;
                            │                     needs an input decision and a review screen
                            │
                            └──▶ WP8 weight+trends ──▶ WP9 calibration
                                                           │
                                                     WP10 CSV export
                                                     WP11 if missed
```

Realistic total: **10–14 evenings** to the end of WP6, which is the version you'd actually keep using. WP4 is the one that will overrun.

---

## Settled, 2026-08-16

1. **Hostname** — `macros.dseifert.net`, as a **subdomain** (settled 2026-08-17). PWA scope `/`.
2. **Repo** — ✅ `seifertd/macrotrack`, private, created and pushed. das's SSH access verified.
3. **Timezone** — `America/Los_Angeles` in the seeds, and it's what the local PG 18 cluster picked up by itself.
4. **Database** — Postgres **18.6**, both machines. Not das's existing 14, and not 19 (GA is ~a month away).
5. **STT** — **Deepgram** (settled 2026-08-17), *and unsettled again on 2026-08-22*: WP5-a ships voice with no provider at all, so this decision now applies only if WP5-b is ever built. Nova-3 with Keyterm Prompting remains the starting point and §2 has the costs; the bake-off is a sanity check on food nouns rather than a provider choice.

## Still needs your answer

1. **`users.name` and email for your wife** — the seeds currently fall back to `Partner` / `partner@dseifert.net`. Set `PARTNER_NAME` and `PARTNER_EMAIL` when you seed production, or edit `db/seeds.rb`.
2. **DNS A record** for `macros.dseifert.net` → das. The one WP2 blocker with lead time.
3. **The PG 18 cluster's port on das** — falls out of your install; write it here when you know it.

---

*Sources for the figures in §2 and the Postgres version decision: [Deepgram STT pricing](https://deepgram.com/learn/best-speech-to-text-apis-2026), [Deepgram Keyterm Prompting docs](https://developers.deepgram.com/docs/keyterm), [AssemblyAI pricing](https://www.assemblyai.com/blog/speech-to-text-api-pricing), [Groq Whisper pricing](https://tokenmix.ai/blog/whisper-api-pricing), [OpenAI Whisper prompting guide](https://developers.openai.com/cookbook/examples/whisper_prompting_guide), [PostgreSQL 18 release](https://www.postgresql.org/about/news/postgresql-18-released-3142/), [PostgreSQL current docs (18.6)](https://www.postgresql.org/docs/current/index.html).*
