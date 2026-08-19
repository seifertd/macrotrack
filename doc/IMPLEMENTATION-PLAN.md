# MacroTrack — Implementation Plan

Companion to `macro-tracker-design.md` (rev. 3). That doc says *what and why*; this one says *in what order, with which commands, and how you know a step is done*.

Ordered so the app is on both phones by the end of WP2, sharing meals between the two of us by the end of WP6a, logging by conversation by the end of WP4, and logging by voice by the end of WP5.

**Build order:** WP1 → WP2 → WP3 → **WP6a** → WP4 → **WP6b** → WP4.5 → **WP7** → WP5 → WP8 → WP9 → WP10.

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
- [x] **Anthropic API key** — in `config/credentials.yml.enc` under `anthropic.api_key`, added 2026-08-18. A Claude Pro subscription does **not** include API access; this is a separate Console org on prepaid credit. Still needed: an STT provider key (§2 below) for WP5. Note the deploy step in WP4 — the credentials file is a Capistrano linked file, so a key added locally does not reach das until it is copied up.

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

**Do the bake-off before writing any voice UI** (WP5.2). One real 20-second clip of one of you rambling about dinner, four providers, count the food nouns each one gets right. Free tiers cover this comfortably.

**Add a fifth column: the phone keyboard's own dictation.** It logged the first four real meals on 2026-08-18 and got every food noun right, for free, so it is the baseline any paid provider has to beat — see WP5. Make the clip hard enough to actually separate them: a recipe name, a self-correction, kitchen noise.

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

So the live preview was checked the honest way: drive it, look at it. Tapping 0.5× on a 360 g / 559 kcal entry sets the field to 180 g and the preview to **280 kcal, 15gP 10gF 25gC** — the plan's worked example, on screen. If someone later gets browser tests stable on this machine, WP5 (recording) and WP7 (barcode) need them far more than this screen does; both are browser-only and neither can be covered any other way.

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

**Still open:** a food with nutrition but no entry (an import) can only be a hint, never a one-tap suggestion, because there is no portion to offer. Magic Juice logs correctly today via the model. Giving imports a portion screen of their own is WP4.5's problem, and it will have ~141 of them.

#### The evidence that moved this up the order

**Evidence from 2026-08-18 that raises the stakes here.** `Foods::EasyfitImport` now pulls hand-picked rows out of the old EasyFit Pro export into `foods` (Magic Juice is in: 81.13 kcal/100g, reconciled from the macros because the export's stated calories were 13% adrift). Asked for "a glass of magic juice", the chat **logged 150 kcal of mango juice** and created a second `foods` row — because nothing reads the table, and §9's instruction to infer a plausible dish from a garbled food name turned a known food into a typo. The instruction that makes dictation work is the one that overrode our own data.

**The reconciliation above ran the wrong way, corrected 2026-08-19.** "Reconciled from the macros" was the wrong call: Doug crafted each EasyFit serving to be the portion he actually eats and the calories he believed it cost, so the **stated calories are the anchor and the macros are the softer number** — the reverse of what `EasyfitImport` shipped with. Measured across all 123 rows the two mostly agree (median macro/stated ratio **1.004**, 104 rows within 10%), so this is a tail problem, not a corpus-wide one; Magic Juice just happens to sit in the tail. It is **71.87 kcal/100g**, not 81.13 — the old figure was 12.9% high. The importer now anchors on the stated calories, rescales the P/C/F split in proportion to match, and flags rows past a 10% gap rather than rejecting them, since a disagreement impugns the split and not the calorie figure.

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

## WP4.5 — Recipe import from Drive *(target: one evening for phase 1, several sittings for phase 2)*

**Goal: the ~141 recipes in the shared Drive folder become `foods` rows, so "log a bowl of the lentil soup" hits retrieval instead of a fresh estimate.** Added 2026-08-17 after the first real friction point: the burst cherry tomato pasta had to be costed by hand, ingredient by ingredient, before it could be logged.

Folder: `0B2s-AeGV6GVJN0ZkYkY1LUdPdU0` (shared — files owned by doug@dseifert.net, doug.seifert@gmail.com, and raquel@dseifert.net).

**A recipe becomes one `foods` row with per-100g macros — not a new Recipe model with ingredients.** `foods` is already per-100g and `meal_entries.quantity_grams` is grams, so a portion is just a weight. This needs no schema change and feeds WP6's repeat-matching for free via the existing trigram index on `foods.name`. A full ingredient model only earns its keep if you want to scale recipes up and down; don't build it on spec.

**Do this after WP4, not before.** It reuses WP4's machinery — parse text into ingredients, look up or estimate nutrition per ingredient, total it. Building it first means building that twice.

### Inventory (counted 2026-08-17)

| Format | Count | Extraction |
|---|---:|---|
| PDF, web print-outs | ~62 | Clean text |
| PDF, 2012-era scans | ~40 | Vision — see below |
| Google Docs | ~34 | Clean text |
| `SeifertFamilyRecipes.docx` | 1 | A compilation; needs splitting into many |
| PNG / JPEG photos | 2 | Vision |
| `.html` / `.mhtml` | 2 | Clean text |

### Phase 1 — the ~100 clean files

Batch script, run once, largely unattended. Extract → ingredients → nutrition per ingredient → total → divide by stated yield → one `foods` row.

**The web print-outs carry their own yield.** The burst tomato pasta PDF contains `Yield: Serves 4` as structured metadata. That's the answer to the hardest number in the whole pipeline, free, for most of the corpus.

### Phase 2 — the ~40 scans

Mostly Raquel's, uploaded in one batch on 2012-07-25: scans of handwritten recipe cards. **Do not use Drive's OCR text** — it is bad in exactly the way that matters. On the Lentil Soup card it read `5 minutes` where the card says **45**, turned "2–3 tsp" into `23+sp`, flattened the brace structure grouping ingredients into two cooking stages, and dropped a caret-inserted "Remove from heat" entirely.

**Reading the page image with a vision model recovers all of it**, including ignoring the bleed-through from *Pigs in the Blanket* printed on the reverse. Verified by hand on 2026-08-17, n=1. Pipeline: `gdrive download → magick -density 200 file.pdf[0] page.png → vision`. The `~/Tools/gdrive` CLI on the workstation is already authenticated.

These are the irreplaceable ones — family recipe cards whose only digital copy is a 2012 scan — so they get a review screen and a slower path. A misread quantity produces confidently wrong macros with nothing to flag it.

### Three things to design for

1. **No yield on the scans.** The cards say nothing like "serves 4". Two quarts of stock and two cups of lentils is obviously a big pot, but per-100g macros need a real number — so weigh the finished dish once, the same fix as for anything cooked from a recipe.
2. **Duplicates.** Lara's Lamb & Rice, Berry Bundt Cake, Sandwich Portabello and Lentil Soup each exist as *both* a Google Doc and a PDF.
3. **Not everything is a dish.** Bourbon Sauce, Thai Curry Peanut Sauce, dry rubs, spice mixes, Horchata, Brandy Alexanders. These want per-tablespoon macros or exclusion, not a serving size.

**Done when:** you can log a portion of a recipe you cooked by naming it, and the macros come from the recipe rather than from a fresh guess.

---

## WP7 — Barcode *(target: one evening)* — **built here, before WP5**

**Moved ahead of voice on 2026-08-17.** Keeps its number so existing references still resolve; only the build order changed. The reason is §6's own principle — prefer ground truth wherever it exists. A packaged product like "a Oui black cherry yogurt, 5 oz" is a label to *read*, not a description to infer from: scanning it is exact and free, while an AI estimate of the same words is a guess that can be off by 20%. It's also one evening's work against voice's two, and it makes every packaged snack accurate before the harder paths land.

Design refs: §7 path 2, §14.6. `BarcodeDetector` (native in Chrome on Android, on-device, free) → OpenFoodFacts lookup → `foods` row with `source: "openfoodfacts"`. Ground truth, no inference. Include a manual-entry fallback for the products OpenFoodFacts doesn't have — it'll be more of them than you expect.

**`BarcodeDetector` is Chrome-on-Android only** — it does not exist in Safari. Both phones in this household are Android (confirmed 2026-08-17), so **no JS fallback is needed**. Worth remembering only if the app ever reaches an iPhone, where the scan button would otherwise fail silently.

---

## WP5 — Voice *(target: two evenings)*

Design refs: §6, §14.4. **Goal: tap, ramble, done.**

### The case for this package narrowed on 2026-08-18 — read this before starting

All four of the first night's entries were dictated into the chat field with the phone keyboard's own mic, and every one came through clean. Gboard transcribed **"Ikea meatballs", "mashed potatoes", "gravy", "roasted broccoli", "mayo, mustard and ketchup"** correctly — precisely the food nouns §6 worried about and specified Deepgram's Keyterm Prompting to solve. It also handled a false start (*"Meatballs I ate six Ikea meatballs half a cup of…"*) that the model absorbed without comment, which is §9's transcript paragraph earning its place.

So speech already works, at zero cost and zero engineering, and those entries are stamped `source: "text"` because as far as the app is concerned they were typed. **The header on this package used to read "the one you actually want." That is no longer the honest framing.** What WP5 still buys, stated plainly:

1. **One tap instead of summoning a keyboard**, which is the actual friction when your hands are busy.
2. **Hands-free while cooking** — dictation still needs you to tap into a text field first.
3. **Vocabulary biasing that improves as `foods` grows.** This is the only one keyboard dictation can never match, and it's also the one with the least evidence behind it so far: n=4, all common foods. It will matter more for the WP4.5 recipe names than it does for a cheeseburger.
4. **Keeping the audio** (§6), which is genuinely invaluable while tuning and is simply not available through the keyboard.

**Two consequences for the bake-off in §2.** Keyboard dictation is now the baseline to beat, not a fallback — run the clip through it alongside the paid providers and require a provider to be *visibly* better before taking the dependency. And the clip should be a hard one: a recipe name, a mumble, a self-correction, background kitchen noise. Four clean sentences from a quiet room will not separate the candidates.

None of this says don't build it. It says the reason to build it is ergonomics, and the plan should stop claiming it is the thing that makes voice possible.

1. **`Stt::Client`** with the one-method interface from §6, plus `Stt::Hosted` and `Stt::Fake`. Faraday multipart for the upload.
2. **Run the bake-off first, before writing the UI.** §17 asks for this and it's genuinely blocking: record one real 20-second clip of one of you rambling about dinner, run it through two or three providers, and pick on **food-noun accuracy**, not latency. Save the clip in `test/fixtures/files/` — it becomes your regression fixture forever.
3. **`POST /voice_entries`**: accepts the blob, attaches it via Active Storage (**keep the audio** — §6 is right that it's invaluable while tuning), transcribes with the vocabulary hint from §6's `foods` query, then hands off to `AiChatTurnJob` with `source: "voice"`.
4. **Recording Stimulus controller**: `getUserMedia` + `MediaRecorder` (`audio/webm;codecs=opus`). **Tap to start, tap to stop.** Live waveform + elapsed timer.
5. **Request a screen wake lock while recording** (`navigator.wakeLock.request("screen")`, released on stop). §6 flags screen-lock-mid-utterance as the most likely place the PWA behaves worse than native — this is the mitigation, and it's four lines. Test it on both phones deliberately: start recording, let the screen go dark, keep talking.
6. **Stage the feedback exactly as §6's table specifies.** The transcript landing at ~2s as your own chat message is the load-bearing detail — it converts a five-second wait into an ordinary conversation. Don't collapse it into one spinner; that throws away the whole design.
7. **Keep the transcript visible** under the parsed result permanently.

**Done when:** you've logged dinner by voice, from the kitchen, with wet hands, while the screen locked — and three weeks later you can still see what you said.

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
                            WP4.5 recipe import (Drive) ──▶ WP7 barcode ──▶ WP5 VOICE ◀── ergonomics,
                                   │                                                       not capability
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
5. **STT** — **Deepgram** (settled 2026-08-17). Nova-3 with Keyterm Prompting; §2 has the costs. The WP5.2 bake-off is now a sanity check on food nouns rather than a provider choice.

## Still needs your answer

1. **`users.name` and email for your wife** — the seeds currently fall back to `Partner` / `partner@dseifert.net`. Set `PARTNER_NAME` and `PARTNER_EMAIL` when you seed production, or edit `db/seeds.rb`.
2. **DNS A record** for `macros.dseifert.net` → das. The one WP2 blocker with lead time.
3. **The PG 18 cluster's port on das** — falls out of your install; write it here when you know it.

---

*Sources for the figures in §2 and the Postgres version decision: [Deepgram STT pricing](https://deepgram.com/learn/best-speech-to-text-apis-2026), [Deepgram Keyterm Prompting docs](https://developers.deepgram.com/docs/keyterm), [AssemblyAI pricing](https://www.assemblyai.com/blog/speech-to-text-api-pricing), [Groq Whisper pricing](https://tokenmix.ai/blog/whisper-api-pricing), [OpenAI Whisper prompting guide](https://developers.openai.com/cookbook/examples/whisper_prompting_guide), [PostgreSQL 18 release](https://www.postgresql.org/about/news/postgresql-18-released-3142/), [PostgreSQL current docs (18.6)](https://www.postgresql.org/docs/current/index.html).*
