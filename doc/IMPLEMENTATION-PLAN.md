# MacroTrack — Implementation Plan

Companion to `macro-tracker-design.md` (rev. 3). That doc says *what and why*; this one says *in what order, with which commands, and how you know a step is done*.

Ordered so the app is on both phones by the end of work package 2 and logging by voice by the end of WP5.

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

**So: build on `localhost` through WP1, and decide before WP2.** If you want the option open, the cheap insurance is to put the base URL in one config value from the start and never hardcode `/` in the manifest or service worker registration. My recommendation is the subdomain — you own the apex, a DNS record is free, and it keeps the PWA at scope `/` where every default just works.

---

## 1. Prerequisites — before WP1

- [x] **Private GitHub repo.** `git@github.com:seifertd/macrotrack.git`, `main` pushed, docs under `doc/`. The Rails app will be generated at the repo *root* (`rails new . --name=macrotrack`) so Capistrano's layout matches the other apps on the box.
- [x] **das can pull from GitHub.** Verified: `ssh -T git@github.com` from das authenticates as `seifertd`. No deploy key needed.
- [x] **Postgres 18.6 installed locally**, running under systemd on the default 5432. `initdb` set local auth to **trust**, so no password is needed for dev connections, and it picked up `America/Los_Angeles` as the cluster timezone on its own. Role `doug` is a superuser.
- [ ] **Install Postgres 18 on das** (your job, per your note). Ubuntu 22.04's own repos stop at 14, so this needs the PGDG apt repo — `postgresql-18` plus **`postgresql-contrib-18`** (that's where `pg_trgm` lives; the app won't migrate without it). It'll come up as a second cluster on the next free port. `pg_lsclusters` will tell you which; put that number in the plan and in `database.yml`.
- [ ] **Postgres role on das.** As the postgres superuser on the *18* cluster: `CREATE ROLE macrotrack LOGIN PASSWORD '...' CREATEDB;` — `CREATEDB` so `db:prepare` can create the cache/queue/cable databases. Password goes in Rails credentials, not `database.yml`.
- [ ] **Confirm the `pg` gem compiles on das** against the new cluster's headers — `libpq-dev` from PGDG (`libpq-dev` tracks the newest installed server). `pg_config` already exists for 14; the real test is `gem install pg` after the 18 packages land.
- [ ] **DNS A record** for `macros.dseifert.net` → das's IP. Not needed until WP2, but propagation is the one thing you can't hurry, so do it as soon as you've settled subdomain-vs-subpath.
- [ ] **Get an Anthropic API key** and an STT provider key (§2 below). Both into `config/credentials/production.yml.enc`.

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

## WP2 — Deploy + PWA install *(target: one evening, possibly two)*

Design refs: §3, §10 PWA specifics, §14.2. **Goal: it's on both phones, and `git push && cap production deploy` is the release process.** Do this before any AI work — the doc is right that three days of real use beats three days of design, and that only starts when it's on the phones.

1. **Copy Capistrano config from chord-practice**: `Capfile`, `config/deploy.rb`, `config/deploy/production.rb`, `config/deploy/templates/systemd_service.erb`, and the capistrano gems in the `:development` group. Change: `:application` to `macrotrack`, `:repo_url`, `deploy_to` → `/home/doug/webapps/macrotrack/production`, app port → **4001**, `.ruby-gemset` → `macrotrack`.
2. **Adapt the systemd template**: add `Environment="SOLID_QUEUE_IN_PUMA=1"` so the job supervisor comes up with the web process. Confirm `plugin :solid_queue if ENV["SOLID_QUEUE_IN_PUMA"]` is present in `config/puma.rb` (Rails 8 generates it).
3. **`linked_files`**: `config/database.yml`, `config/master.key`, `config/credentials.yml.enc`, `config/credentials/production.key`. **`linked_dirs`**: the chord-practice list plus **`storage`** — Active Storage will hold the audio blobs from WP5 and they must survive a release swap.
4. **Production `database.yml` on the host** (in `shared/config/`) with `host: 127.0.0.1`, `username: macrotrack`, password from credentials, and **the PG 18 cluster's port** — confirm with `pg_lsclusters`, don't assume 5432 (14 is already squatting on 5434).
5. **nginx vhost** `/etc/nginx/conf.d/macros.dseifert.net.conf`, modeled on chord-practice's: `upstream macrotrack { server localhost:4001; }`, asset caching block, and **`client_max_body_size 25M`** — voice uploads are small, but the default 1M will bite you the first time you ramble for 90 seconds. Then `sudo certbot --nginx -d macros.dseifert.net`.
6. **PWA bits**: `manifest.json` (`display: "standalone"`, `start_url: "/"`, `theme_color`, 192px and 512px icons), a minimal service worker registered on first load. Skip `apple-touch-icon`.
7. **Install on both phones** via Chrome → Install app. Verify it lands in the app drawer with its own task-switcher entry.

**Done when:** both of you have logged a real meal from your phone, from the home-screen icon, over HTTPS, and a `cap production deploy` of a trivial change shows up without reinstalling.

**Then use it manually for a few days.** Everything after this is friction reduction; you want to know which friction actually annoys you before optimizing it.

---

## WP3 — Backups *(target: 30 minutes)*

Design refs: §13. The doc says this "arguably belongs at step 2." It does — move it here. You now have real data and no copies of it.

- Nightly cron on das: `pg_dump` (with the `-p 5434`) → gzip → `/home/doug/webapps/backups/macrotrack/`, retain 30 days.
- `rsync` that directory to a home machine, or push to object storage. One of the two, not neither.
- Restore-test it **once, now**: load last night's dump into a scratch database and count rows. An untested backup is a belief, not a backup.

**Done when:** you have restored a dump you didn't create by hand.

---

## WP4 — Conversational logging, text only *(target: two or three evenings — the biggest package)*

Design refs: §8, §9, §15, §16, §14.3. **Goal: type "a bowl of chili and a slice of sourdough with butter" and it gets logged.**

Build in this order; each step is independently testable:

1. **`Ai::MealTools`** — §15 verbatim. Pure data, no behavior, no tests needed beyond a schema-shape sanity check.
2. **`Ai::ToolHandlers`** — §16 verbatim. **This is where the tests go.** It's plain Ruby taking a hash and touching the database, so test it directly with no API in the loop: `log_meal` creates an entry and returns the ID; `update_meal` is user-scoped and can't touch the other user's row; `copy_to_household_member` copies and raises when there aren't exactly two users; an exception produces `is_error: true` rather than blowing up the turn.
3. **`Conversation` / `Message`** with `#to_api_messages` (windowed to ~10 turns per §9), `#last_user_text`, `#last_input_source`. `content` is stored as raw Anthropic content blocks and replayed verbatim — resist the urge to normalize it into your own shape; the whole point is that it round-trips.
4. **`Ai::Prompts.meal_logging(user)`** — §9's prompt, plus today's totals injected. **Keep the cacheable prefix byte-stable**: put the `cache_control` breakpoint on the last static system block, and inject the volatile part (totals, current time) *after* it or in the user turn. An interpolated timestamp above the breakpoint silently kills caching, and nothing will tell you.
5. **`AiChatTurnJob`** — §16 verbatim, including `MAX_ITERATIONS = 5`, adaptive thinking, `effort: "low"`, `max_tokens: 8192`. Do not "optimize" by disabling thinking; §8 explains the silent-failure trap in detail.
6. **A fake client for tests.** `Ai.client` should be swappable to an `Ai::FakeClient` returning canned responses — one with a `tool_use` block, one with plain text, one with two tool calls in a single turn (to prove all results go back in **one** user message). This is the invariant most likely to break and the one hardest to notice.
7. **Chat UI + Turbo Streams**: user message appends immediately, typing indicator while the job runs, assistant message and confirmation card stream in, header totals update.

**Done when:** a novel meal logs correctly from the chat, a follow-up correction ("make that double chicken") updates the same entry rather than creating a second one, and the whole suite passes with zero network calls.

**Watch for:** cost sanity. Log `usage` from every response into `messages.token_estimate` from day one. At ~120 parses/month you should see single-digit dollars; if you see more, something is looping.

---

## WP5 — Voice *(target: two evenings — the one you actually want)*

Design refs: §6, §14.4. **Goal: tap, ramble, done.**

1. **`Stt::Client`** with the one-method interface from §6, plus `Stt::Hosted` and `Stt::Fake`. Faraday multipart for the upload.
2. **Run the bake-off first, before writing the UI.** §17 asks for this and it's genuinely blocking: record one real 20-second clip of one of you rambling about dinner, run it through two or three providers, and pick on **food-noun accuracy**, not latency. Save the clip in `test/fixtures/files/` — it becomes your regression fixture forever.
3. **`POST /voice_entries`**: accepts the blob, attaches it via Active Storage (**keep the audio** — §6 is right that it's invaluable while tuning), transcribes with the vocabulary hint from §6's `foods` query, then hands off to `AiChatTurnJob` with `source: "voice"`.
4. **Recording Stimulus controller**: `getUserMedia` + `MediaRecorder` (`audio/webm;codecs=opus`). **Tap to start, tap to stop.** Live waveform + elapsed timer.
5. **Request a screen wake lock while recording** (`navigator.wakeLock.request("screen")`, released on stop). §6 flags screen-lock-mid-utterance as the most likely place the PWA behaves worse than native — this is the mitigation, and it's four lines. Test it on both phones deliberately: start recording, let the screen go dark, keep talking.
6. **Stage the feedback exactly as §6's table specifies.** The transcript landing at ~2s as your own chat message is the load-bearing detail — it converts a five-second wait into an ordinary conversation. Don't collapse it into one spinner; that throws away the whole design.
7. **Keep the transcript visible** under the parsed result permanently.

**Done when:** you've logged dinner by voice, from the kitchen, with wet hands, while the screen locked — and three weeks later you can still see what you said.

---

## WP6 — Repeat-meal matching + "also log for" *(target: one evening)*

Design refs: §7 (paths 1 and the household affordance), §14.5. Highest leverage per hour of work in the entire plan, and zero AI cost.

- `Food.match_or_create(name)` using `pg_trgm` similarity, scoped first to both users' last 90 days, then global `foods`. Tune the similarity threshold against your real data, not a guess.
- Surface matches in the chat before inference runs: "the usual chicken bowl — 780 cal?" is retrieval, not estimation.
- **"Also log for \<name\>"** button on every entry (the tool already exists from WP4).
- Instrument the hit rate — a counter is enough. It's the number that tells you whether §17's `pg_trgm`-vs-`pgvector` question needs answering at all.

**Done when:** a dinner you've eaten before logs without an API call, and one tap puts it on the other person's day too.

---

## WP7 — Barcode *(target: one evening)*

Design refs: §7 path 2, §14.6. `BarcodeDetector` (native in Chrome on Android, on-device, free) → OpenFoodFacts lookup → `foods` row with `source: "openfoodfacts"`. Ground truth, no inference. Include a manual-entry fallback for the products OpenFoodFacts doesn't have — it'll be more of them than you expect.

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
                            WP4 chat+tool loop ──▶ WP5 VOICE ◀── the point of the project
                                   │
                                   ├──▶ WP6 repeat-match + also-log-for   (biggest win/hour)
                                   ├──▶ WP7 barcode
                                   └──▶ WP8 weight+trends ──▶ WP9 calibration
                                                                  │
                                                            WP10 CSV export
                                                            WP11 if missed
```

Realistic total: **10–14 evenings** to the end of WP6, which is the version you'd actually keep using. WP4 is the one that will overrun.

---

## Settled, 2026-08-16

1. **Hostname** — `macros.dseifert.net`. Subdomain-vs-subpath still open, but must close before WP2, not before WP1; see §0.
2. **Repo** — ✅ `seifertd/macrotrack`, private, created and pushed. das's SSH access verified.
3. **Timezone** — `America/Los_Angeles` in the seeds.
4. **Database** — Postgres **18.6**, both machines. Not das's existing 14, and not 19 (GA is ~a month away).
5. **STT** — shortlist and real costs in §2. Deepgram Nova-3 is the recommended starting point; bake-off in WP5.2 decides.

## Still needs your answer

1. **`users.name` for both of you** — explained in WP1.2. Two first names is all this is.
2. **Subdomain or `www.dseifert.net/macros`** — deadline is WP2. Recommendation and the actual cost of the subpath are in §0.
3. **Which STT provider wins the bake-off** — a WP5 decision, made with data rather than by picking now.
4. **The PG 18 cluster's port on das** — falls out of your install; write it here when you know it.

---

*Sources for the figures in §2 and the Postgres version decision: [Deepgram STT pricing](https://deepgram.com/learn/best-speech-to-text-apis-2026), [Deepgram Keyterm Prompting docs](https://developers.deepgram.com/docs/keyterm), [AssemblyAI pricing](https://www.assemblyai.com/blog/speech-to-text-api-pricing), [Groq Whisper pricing](https://tokenmix.ai/blog/whisper-api-pricing), [OpenAI Whisper prompting guide](https://developers.openai.com/cookbook/examples/whisper_prompting_guide), [PostgreSQL 18 release](https://www.postgresql.org/about/news/postgresql-18-released-3142/), [PostgreSQL current docs (18.6)](https://www.postgresql.org/docs/current/index.html).*
