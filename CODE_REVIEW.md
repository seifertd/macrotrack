# Code review — DRYness, performance, security

Reviewed 2026-08-23 against `main` at 5c6d93d. Whole codebase, not a diff.

> **Status 2026-08-23 (later the same day):** the five items in "Fix in this order" are
> done, plus 1.4, 2.2, 2.5 and 2.8. Each fixed finding is marked **FIXED** in place below,
> and the full accounting — including what was measured after — is in
> [What was fixed](#what-was-fixed) at the end. 284 tests green, rubocop clean, brakeman
> still 0/3-ignored.

Query counts and generated SQL below were measured against the development database
inside rolled-back transactions, not inferred from reading. Everything else is
grep- or file-verified, with file:line references.

---

## Baseline: what's already solid

Worth stating up front, because it shapes the severity of everything below.

- `brakeman` reports **0 security warnings** (3 ignored, each with a reasoned note in
  `config/brakeman.ignore`).
- `bundler-audit` reports **no vulnerable gems** against the 2026-08-22 advisory DB.
- `config/master.key` is gitignored and untracked; only `credentials.yml.enc` is committed.
- Every user-supplied SQL fragment goes through `sanitize_sql_array` before interpolation,
  and the two places that could have gone wrong — `Food.name_match_sql`,
  `Meals::Matcher#score_sql` — carry comments explaining exactly why.
- Record finders are user- or household-scoped: `meal_entries_controller.rb:55`,
  `repeats_controller.rb:50`, `chat_suggestions_controller.rb:39`.
- Tool input from the model is whitelisted before mass assignment (`tool_handlers.rb:33`).
- Whisper is invoked with an argv array, not a shell string.
- `force_ssl` and `assume_ssl` are on in production.

---

## 1. DRYness

### 1.1 `repeats/show.html.erb` is a near-verbatim copy of `shared/_portion_form.html.erb` — **FIXED**

The largest duplication in the codebase. The grams input (`repeats/show:24-30` vs
`_portion_form:28-34`), the chip loop (`:38-48` vs `:38-48`), and the entire "That's"
preview section (`:52-67` vs `:51-66`) are byte-identical apart from `@source.calories`
vs `base[:calories]`. Both wire the same five `portion_*_value` data attributes to the
same Stimulus controller.

The blocker is that `FoodPortion` has `chips` / `reference_grams` / `reference_scaled`
and `MealPortion` doesn't. Give `MealPortion` those three and one partial serves all
three screens.

**Cost today:** any change to the portion UI has to be made twice, and the two copies
have already drifted — the food form shows a serving line, the repeat form shows a
"wasn't weighed" note.

### 1.2 `FoodPortion` and `MealPortion` share three method bodies — **FIXED**

- `decimal` (`food_portion.rb:141`) and `presence_as_decimal` (`meal_portion.rb:82`) are
  identical down to the rescue.
- `attributes_for` / `log_for!` have the same shape and the same `.except(:user)` trick
  (`food_portion.rb:101-114`, `meal_portion.rb:47-62`).
- `scaled` is the same transform over a different constant.

A shared `Portion` concern would hold all three.

### 1.3 `messages/_entry_card.html.erb:2-32` duplicates `days/show.html.erb:19-48`

Same name/time/meal-type/grams line, same kcal + P/F/C block, same
confidence-badge-plus-assumptions block.

They have already drifted in a way that matters: the day view relies on the
`use_user_time_zone` around_action and calls `entry.consumed_at.strftime` bare
(`days/show:23`), while the card calls `.in_time_zone(user.timezone)` explicitly
(`_entry_card:7`). Two ways of answering the same question is how one of them ends up
wrong.

### 1.4 The "log a portion, redirect to the day" epilogue is written three times — **FIXED**

`foods_controller.rb:33-34`, `repeats_controller.rb:43-44`, `scans_controller.rb:54-55`
— identical including the notice string.

### 1.5 The search ranking rule is expressed twice, in two languages

`repeats_controller.rb:75-79` rebuilds `word_score_sql` / `whole_score_sql` for the
`ORDER BY` even though `scored_against` already selected them as `word_score` /
`whole_score`; then `ScoredByName.by_confidence` (`scored_by_name.rb:27`) re-implements
the same ordering in Ruby.

The SQL ordering isn't dead — it decides which 50 rows survive `LIMIT` — but the
tie-break rule now lives in two places.

### 1.6 Three copies of the swappable-singleton pattern

`Ai.with_client` (`ai.rb:18`), `OpenFoodFacts.with_connection` (`open_food_facts.rb:42`),
`Stt.with_provider` (`stt.rb:16`). Defensible as three independent seams; worth knowing
it is three.

### 1.7 `Food.match_or_create` is a pure delegation

`food.rb:102` delegates to `find_or_create_by_name`. The comment justifies it as a future
seam — noted, not a defect.

---

## 2. Performance

All of the following were measured, not inferred.

### 2.1 The day page runs the same aggregate three times, one of which nothing reads — **FIXED**

`days_controller.rb:7` sets `@totals`, and `@totals` appears nowhere else in the codebase
(grep-verified). Meanwhile `_header_strip.html.erb:8` calls `day_totals` and `:10` calls
`calories_remaining`, which calls `day_totals` again (`user.rb:73`).

**Measured:** 2 identical `SELECT COALESCE(SUM(...))` queries for the header alone, plus
the dead one from the controller.

**Fix:** delete `@totals`, and have the partial derive `remaining` from the totals it
already has.

### 2.2 The repeat search joins `foods` twice — **FIXED**

`MealEntry.named_like` does `left_joins(:food)` while `recent_in_household` does
`includes(:food, :user)`; the string `where` forces the includes into an eager_load, and
Rails emits both joins:

```sql
LEFT OUTER JOIN "foods" ON "foods"."id" = "meal_entries"."food_id"
LEFT OUTER JOIN "foods" "foods_meal_entries" ON "foods_meal_entries"."id" = ...
```

The eager_load also hauls every `users` column into the web process per row — including
`password_digest`, a bcrypt hash, for each search result.

**Fix:** add `references(:food)` and drop the redundant `left_joins`, or preload `:user`
separately.

### 2.3 The similarity functions are computed twice per row in `matching_foods`

Verified SQL: `COALESCE(GREATEST(word_similarity('chicken', foods.name)), 0)` appears once
in the `SELECT` and again in the `ORDER BY`.

Postgres accepts `ORDER BY word_score DESC, whole_score DESC` against the output aliases,
halving the trigram work on the matched set.

### 2.4 `Conversation#last_user_text` loads the entire thread into memory — **FIXED**

`messages.reverse_each` (`conversation.rb:22`) is not a relation method, so it falls
through to `each` and loads every row.

**Measured:** 60 messages, one query, all 60 instantiated. `ChatsController:3-5` already
documents that this is "a few thousand rows after a year" — and this method runs on every
chat turn, from `ai_chat_turn_job.rb:29` and `tool_handlers.rb:36`.

**Fix:** `messages.order(created_at: :desc, id: :desc).limit(WINDOW).find(&:spoken?)`
bounds it.

### 2.5 N+1 in the AI prompt's hints block — **FIXED**

`Meals::Matcher#scored_entries` uses `joins(:user, :food)`, not `includes`, so
`Ai::Prompts.describe` firing `entry.user.local_date(...)` (`prompts.rb:107`) issues one
query per entry hint.

**Measured:** 2 extra `SELECT "users"` queries for a 5-hint block; scales with
`HINT_LIMIT`. This sits on the paid-inference path, so it is latency in front of a user
watching a spinner.

### 2.6 `meal_entries.raw_input` has no trigram index

It is searched with exactly the same `ILIKE '%…%' OR word_similarity(…)` predicate as
`foods.name`, which does have one (`schema.rb:81`). Every entry search is a sequential
scan on that column.

Irrelevant at current row counts; the asymmetry is the finding.

### 2.7 Three redundant indexes

`index_meal_entries_on_user_id` (`schema.rb:108`), `index_weight_entries_on_user_id`
(`:158`), and `index_messages_on_conversation_id` (`:121`) are each a left-prefix of an
existing composite on the same table. They cost write throughput and buy no reads.

### 2.8 The whisper `nice` claim is not true — **FIXED**

`config/initializers/stt.rb` says the two threads are "niced by the caller" — nothing
nices it. `Stt::Whisper#transcribe` calls `Open3.capture3` at normal priority, inline in
one of Puma's 3 threads (`config/puma.rb`), with `SOLID_QUEUE_IN_PUMA=1` putting the job
workers in the same process, on a 2-core box.

The inline-transcription trade is deliberate and well-argued at
`voice_entries_controller.rb:26-31`. The stale comment is the actual defect, since it
describes a mitigation that does not exist.

### 2.9 `volatile_block` reads the same day twice

`Ai::Prompts.volatile_block` runs `day_totals` as its own `SUM` and then `log_block` loads
the same day's entries (`prompts.rb:117`).

**Measured:** 2 queries, where the totals could be summed from the rows already in hand.

---

## 3. Security

### 3.1 Production mail is still on the generator's placeholders — HIGH — **FIXED**

`config/environments/production.rb:61` sets `default_url_options = { host: "example.com" }`
and `app/mailers/application_mailer.rb:2` sets `from: "from@example.com"`; `smtp_settings`
is commented out.

`PasswordsMailer` builds its link with `edit_password_url` (`reset.html.erb:3`), so a
production password reset generates `https://example.com/passwords/<signed-token>/edit` —
a valid 15-minute reset token addressed to a domain you do not control.

Delivery is almost certainly failing today, which is what is containing it. The moment
SMTP is configured without fixing the host, it stops being contained.

### 3.2 No password strength validation at all — **FIXED**

`User` has `has_secure_password` and no length constraint.

**Verified:** a one-character password saves clean, `valid? == true`, no errors. Rails only
enforces the 72-byte bcrypt ceiling.

### 3.3 No Content-Security-Policy

`config/initializers/content_security_policy.rb` is the generator stub, entirely commented
out — no CSP header is sent.

ERB autoescaping is doing the real work and `_message.html.erb:21` correctly passes
`sanitize: true` to `simple_format`, so there is no live XSS. But this app renders three
streams of text it did not author — model output, OpenFoodFacts product names, and whisper
transcripts — which is precisely the case CSP exists to backstop.

### 3.4 No rate limit on the two endpoints that cost money and CPU

`sessions#create` and `passwords#create` are limited (`sessions_controller.rb:3`,
`passwords_controller.rb:4`). `chat_messages#create` and `voice_entries#create` are not.

Each typed turn is a `claude-opus-5` call with an 8192-token budget; each recording is
8–12s of both cores. Both are authenticated, so this is abuse-by-a-known-account or a
runaway client rather than an open door — but with two users and a metered API, a stuck
retry loop is a real bill.

### 3.5 `config.hosts` is unset in production

`production.rb:83-86`, commented. nginx forwards `Host $http_host` verbatim
(`config/deploy/nginx/macros.dseifert.net.conf:53`), so Host-header injection is blocked
only if that vhost is not the accidental `default_server` for :443 — which depends on what
else is in `sites-enabled` and is not visible from this repo.

### 3.6 Sessions never expire

`cookies.signed.permanent[:session_id]` (`authentication.rb:44`) is a 20-year cookie
against a `sessions` row with no expiry column, no rotation, and no UI to review or revoke.

`httponly` and `same_site: :lax` are set, and a password reset does `sessions.destroy_all`
— so the main exposure is a cookie captured from a device later out of your hands.

### 3.7 Voice uploads are unvalidated server-side

`voice_entries_controller.rb:8-15` checks only `blank?` before attaching to ActiveStorage
and handing the path to whisper. No content-type check, no size check — nginx's
`client_max_body_size 25M` is the only bound, and it is 25MB by design for long clips. A
25MB non-audio blob is stored, then fails in whisper.

Blobs are never served back (no `rails_blob_path` anywhere in the views), so there is no
stored-XSS path. This is a resource question, not a content one.

### 3.8 `PlanDocument` renders Redcarpet output with `html_safe`

`plan_document.rb:47`, and `Redcarpet::Render::HTML.new` is constructed with no
`escape_html` or `filter_html` (`:56`), so raw HTML in the markdown passes through to the
page.

The source is `doc/IMPLEMENTATION-PLAN.md` from the deployed release — content you wrote
and committed — so this is safe today. Worth flagging only because the safety is entirely
a property of where the file comes from, and nothing in the class enforces that.

### 3.9 Free-text meal descriptions reach production logs

`OffersRetrieval#log_retrieval` (`offers_retrieval.rb:21-26`) logs a 60-character
truncation of what the user said at `info`, and Rails logs request params at `info` too,
so `chat_message[text]` lands in the journal as well. `filter_parameters` covers `:email`
but not this.

The §7 hit-rate instrumentation is a deliberate and well-justified choice. Noting only
that what is being logged is dietary free text, at production's default log level.

---

## What was fixed

Applied 2026-08-23. Query counts below were measured after the change, the same way the
findings were: against the development schema inside rolled-back transactions.

| # | What changed | Measured after |
|---|--------------|----------------|
| 3.1 | `production.rb` now points at `macros.dseifert.net` with `protocol: "https"`, and the mailer's `from` is `no-reply@macros.dseifert.net`. | A reset link is now built for a host we control. |
| 2.1 | Dead `@totals` deleted from `days_controller`; `User#remaining_from` split out of `calories_remaining` so the header strip subtracts from the totals it already loaded. | **3 → 1** `COALESCE(SUM(...))` per day page — and the strip is in the layout, so this is every page. |
| 2.4 | `last_user_text` and `last_input_source` both go through a new private `recent_first`, bounded to `WINDOW`. | **33 → ≤20** rows instantiated on a 33-row thread; flat from here rather than growing. |
| 1.1 | `repeats/show.html.erb` is now a header plus `render "shared/portion_form"` — 73 lines to 12. `MealPortion` gained `reference_grams` / `reference_scaled` / `chips` so one partial serves all three screens. | Rendered HTML for all four screens (repeat weighed/unweighed, food with/without a serving) diffed against the old templates: identical but for whitespace and the deliberate `tabular-nums` on the repeat chips. |
| 3.2 | `User::MINIMUM_PASSWORD_LENGTH = 12`, `validates :password, length:, allow_nil: true`. `PasswordsController#update` now reports the real validation error instead of always saying "Passwords did not match". | A 1-character password no longer saves. Existing sessions and logins are untouched — the rule only runs when a password is being set. |
| 1.4 | `redirect_to_logged_day(entry)` on `ApplicationController`; the three controllers call it. | Notice string and target day now have one definition. |
| 2.2 | `recent_in_household` preloads instead of includes. | Second `foods` join gone; `users.password_digest` no longer selected into the web process at all. Search path is **3 queries for 8 rows**, no N+1. |
| 2.5 | `scored_entries` preloads `:user, :food` (preload, not includes — an eager_load would rewrite the `match_score` select away). | **12 → 4** queries for a 5-hint block, on the paid-inference path. |
| 2.8 | The `nice` claim in `config/initializers/stt.rb` replaced with what actually happens, and `WHISPER_THREADS` named as the lever. | — |

Tests: 284 green (6 added). `rubocop` clean. `brakeman` back to 0 warnings / 3 ignored —
the `.preload` in `matcher.rb` changed the fingerprint of an already-reviewed ignore entry,
so that entry was re-pointed with its reasoning intact rather than a new warning suppressed.

### Deliberately not done

- **3.2's length is a judgement call.** 12 is a constant on one line; there is no signup
  route, so it only ever gates the reset form. Lower it if it annoys you.
- **2.3, 2.9** — query-shape cleanups that do not bite at two users, and 2.3 in particular
  wants its `ORDER BY`-by-alias rewrite measured against the ranking tests rather than
  assumed.
- **2.6, 2.7** — both need migrations, and 2.6's own text says it is irrelevant at current
  row counts. Worth batching into one schema pass rather than three.
- **3.3–3.9** — defense-in-depth, and two of them (3.4's rate limits, 3.5's `config.hosts`)
  can lock you out of your own app if they land unattended. They want a deploy you are
  watching, which is a different session from this one.

---

## Fix in this order

| # | Finding | Why it goes here |
|---|---------|------------------|
| 1 | **3.1** — reset-link host (`production.rb:61`, `application_mailer.rb:2`) | The only finding that hands a live credential to a domain you do not own. Two-line fix. |
| 2 | **2.1** — delete `@totals`, derive `remaining` from loaded totals | Smallest diff in the list; three identical aggregates become one. |
| 3 | **2.4** — bound `Conversation#last_user_text` | The only finding that gets measurably worse every day the app is used. |
| 4 | **1.1** — collapse `repeats/show.html.erb` into `_portion_form` | Biggest maintenance win, and it stops the two copies drifting further. |
| 5 | **3.2** — minimum password length | One validation line; closes the weakest remaining auth gap. |

Everything else is real but can wait: 2.2/2.3/2.5 are query-shape cleanups that do not
bite at two users, 2.6/2.7 are schema tidying, 2.8 is a stale comment, and 3.3–3.9 are
defense-in-depth on an app with two known accounts behind TLS.

*(All five of the above are done, along with 1.4, 2.2, 2.5 and 2.8 — see
[What was fixed](#what-was-fixed).)*
