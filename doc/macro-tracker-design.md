# MacroTrack — Design Doc (rev. 3)

AI-assisted calorie/macro tracker for **two people: me and my wife**. Rails 8, installed as a PWA on two Android phones. Not a product.

> **What changed in rev. 3:** this is no longer a business. Deleted: monetization, tiers, quotas, BYO-key, IAP/RevenueCat, App Store compliance, the retention gate, install/churn projections, and most of the model-cost analysis — at two users the AI bill is a rounding error, so "pick the cheap model" is no longer a constraint worth designing around. Hotwire Native is demoted from day-one requirement to a later escape hatch, because "must ship to an app store" was the only thing forcing it. Voice is promoted from a footnote to a primary design concern and rescoped: **record → server-side STT → Claude**, not the Web Speech API. Model guidance updated to current API behavior (thinking is on by default on Opus 5; rev. 2's "disable thinking on the parse path" is now actively harmful for a tool-calling app). Exercise/Health and calibration move behind food logging.

---

## 1. Goals

- Kill the "look up grams of protein/fat/carbs and convert to servings" friction that kills adherence.
- **Measure hands-and-attention time, not elapsed time.** The goal is that logging a novel meal costs one tap, one sentence, and one glance — under ten seconds of *your* involvement. A few seconds of the app thinking afterwards costs nothing, as long as it visibly says so (§6). Optimize for how long you're held up, not for wall-clock.
- **Talk to it.** A mic button, one long rambling sentence, done. This is the feature we actually care about.
- Two accounts, separate logs, shared food database, one household.
- It should still work in two years without either of us maintaining it weekly.

**Explicit non-goals:** absolute accuracy (§2), other users, an app store, revenue.

---

## 2. Positioning — the accuracy problem, stated honestly

This still drives most of the design, so it still comes first. It's no longer about marketing; it's about the two of us agreeing up front what these numbers are.

**You cannot determine macros from a photo, and largely can't from a description either.** A tablespoon of olive oil is ~120 kcal and 14g of fat, and it's invisible once absorbed into a stir-fry. Sautéed vegetables look identical to steamed. Restaurant kitchens use far more butter than home cooks and you can't see any of it. Depth and density are unrecoverable from a 2D image (a bowl of rice is 150g or 350g depending on the bowl). Whole vs. skim milk in a latte, full-fat vs. 0% yogurt — visually identical.

A single meal estimate can be off by **300–500 kcal in either direction**. If the target deficit is 500 kcal/day, the signal is inside the noise.

This is not a model capability gap that a better model fixes. The information is not in the input. Trained dietitians estimating portions from photographs have substantial error rates for the same reason.

**Three consequences:**

1. **Don't trust a single day's number.** The accurate alternative — kitchen scale plus USDA lookups — has near-zero adherence, which is the entire premise of §1. We're trading precision for the fact that we'll actually do it.
2. **Prefer ground truth wherever it exists.** Barcode and nutrition-label OCR are *reading*, not estimating. Matching against a meal one of us already logged is *retrieval*, not estimating. Both are more accurate and cheaper than inference. See §6.
3. **Make the imprecision not matter, statistically.** High-variance error can't be calibrated away per-meal, but it averages out over weeks — and systematic error can be backed out from weight trend. See §9. Daily numbers are noise; weekly trend plus weight is signal, and the UI should say so.

Surface uncertainty rather than hiding it: the `confidence` and `assumptions` fields are shown in the UI, and correcting an entry is one tap.

**What being a two-person app changes here:** §9's calibration is *easier*, not harder. With two subjects you can eyeball the chart yourself and hand-adjust `logging_bias_factor` if the fit looks wrong. There's no need for the automated version to be robust across a population — it needs to work for exactly two people whose data you can look at directly.

---

## 3. Platform — why web, and what it costs

Both phones are Android. That collapses the question.

### The decision

**Build a Rails web app and install it as a PWA on both phones.** No app store, no native shell, no signing.

| | PWA on Android | Hotwire Native Android |
|---|---|---|
| Distribution | Chrome → Install app → WebAPK in the app drawer | Sideload an APK, or Play Store |
| Deploy a change | `git push` + Kamal, live in a minute | Server screens instantly; shell changes need a new APK |
| Signing / expiry | none | self-signed APK, installs forever, no store needed |
| Camera (photo, barcode) | ✅ `getUserMedia`, `BarcodeDetector` | ✅ |
| Microphone | ✅ `getUserMedia` + `MediaRecorder` | ✅ + native STT |
| Offline queue | ✅ service worker + IndexedDB | ✅ |
| Push notifications | ✅ Web Push | ✅ |
| **Health Connect** | ❌ **no web API, at all** | ✅ |
| **Home screen widget** | ❌ | ✅ |

Two things a PWA genuinely cannot do: **Health Connect** and **widgets**. Both are on the "nice to have, not day one" list, so neither blocks anything.

### Why the escape hatch is cheap (and this is Android-specific)

Adding a Hotwire Native Android shell later is a thin Kotlin wrapper around the same Turbo screens — days of work, not weeks — and on Android you can build a signed APK, install it on two phones, and it works forever. No developer program, no store review, no 90-day TestFlight expiry, no annual re-signing. **The iOS version of this decision would be much more fraught**; the Android version is genuinely low-stakes. So:

> **Ship the PWA. If living without Health Connect turns out to be annoying, add the shell then.** The Rails app doesn't change either way.

### Hosting

Public subdomain on the existing Linode, deployed with Kamal alongside chord-practice.com. HTTPS via Let's Encrypt (required anyway — `getUserMedia` and service workers don't run without it).

The tempting alternative is to expose it only on the Tailscale tailnet (`macros.<tailnet>.ts.net`, real cert via Tailscale Serve, no public exposure, no auth hardening). **Don't.** You will want to log a meal while standing in a restaurant on hotel wifi with the VPN in a bad mood. A public subdomain with a login is less to go wrong at the exact moment you need it.

---

## 4. Auth — two seeded users, no signup

Rev. 2 specified Devise with `confirmable` because a public app plus a shared API key is an abuse vector. Neither premise holds now.

Use **Rails 8's built-in authentication generator** (`bin/rails generate authentication`) — session-based, `has_secure_password`, ~200 lines you can read. Then:

- **No registration route.** Two users seeded in `db/seeds.rb`. Delete `SessionsController#new`'s signup link.
- **Long-lived signed session cookies** (`expires: 1.year`) so neither of us ever sees a login screen on our own phone.
- One Anthropic API key in Rails credentials. No key routing, no per-user credentials, no `ai_credentials` table.

That's the whole auth story. Devise, `confirmable`, and email deliverability are all deleted.

---

## 5. Data Model

> **Correction (2026-08-17): the app does not assume exactly two users.** Rev. 3 originally
> asserted a two-person household in code (`User.where.not(id: user.id).sole`) and called that
> "an assertion of the app's core assumption." That was a mistake — it's the kind of assumption
> that's free to allow for now and expensive to retrofit, because "the other user" appears in a
> tool schema, a dispatcher, and a UI affordance. There is now a `households` table; sharing is
> scoped to a household, which happens to contain two people today. Two people remains the
> *design case* — the UI is tuned for it and there is still no signup route — but nothing
> breaks when a third account appears.

```ruby
create_table :households do |t|
  t.string   :name, null: false                       # "Seifert" — the unit that shares a kitchen
  t.timestamps
end

create_table :users do |t|
  t.references :household, null: false                # sharing is scoped to this, not to "all users"
  t.string   :name, null: false                       # "Doug" — shown on shared entries, and on the
                                                      # "also log for <name>" button
  t.string   :email_address, null: false              # the auth generator's column name, not :email
  t.string   :password_digest, null: false
  t.string   :timezone, null: false, default: "UTC"   # REQUIRED — see note below
  t.integer  :daily_calorie_target, default: 2000
  # calibration outputs (§9)
  t.decimal  :estimated_tdee
  t.decimal  :logging_bias_factor, default: 1.0
  t.datetime :calibrated_at
  t.timestamps
end
```

> **Timezone is not optional.** For a calorie tracker "what day was this" *is* the product — an 11pm snack could otherwise land on tomorrow's total. Every daily rollup goes through `user.timezone`. (Still true with two users in the same timezone: it's about the UTC-datetime → local-date conversion, not about multiple zones.)

Gone from rev. 2's `users`: `subscription_tier`, `byo_enabled`, `ai_parses_this_period`, `period_started_at`. There is no metering.

```ruby
# One conversation per user; messages are windowed (§7).
create_table :conversations do |t|
  t.references :user, null: false
  t.references :last_meal_entry, foreign_key: { to_table: :meal_entries }
  t.timestamps
end

create_table :messages do |t|
  t.references :conversation, null: false
  t.string  :role, null: false        # user | assistant
  t.jsonb   :content, null: false     # raw Anthropic content blocks, replayed verbatim
  t.integer :token_estimate
  t.timestamps
end
add_index :messages, [:conversation_id, :created_at]
```

```ruby
# foods — canonical/cached items, shared by every user (not scoped to a household).
# This is how repeat meals avoid inference entirely, and the hit rate is better than
# it would be for one person alone: a nutrition database has no reason to be private.
create_table :foods do |t|
  t.string  :name, null: false
  t.string  :source                # usda | openfoodfacts | ai_estimate | user_custom
  t.string  :barcode               # nil unless scanned
  t.decimal :calories_per_100g
  t.decimal :protein_per_100g
  t.decimal :fat_per_100g
  t.decimal :carbs_per_100g
  t.jsonb   :raw_ai_response       # full response, kept for debugging
  t.timestamps
end
add_index :foods, :barcode, unique: true, where: "barcode IS NOT NULL"
add_index :foods, :name, using: :gin, opclass: :gin_trgm_ops
```

> Rev. 2 warned "never store user free text here — shared table, privacy." Irrelevant now; it's a household. Keep the whole raw response, it's the only thing that makes a bad parse debuggable three weeks later.

```ruby
create_table :meal_entries do |t|
  t.references :user, null: false
  t.references :food, null: true
  t.string   :raw_input             # what was typed, or the voice transcript
  t.string   :source, null: false   # barcode | matched | photo | voice | text | manual | copied
  t.decimal  :quantity_grams
  t.decimal  :calories
  t.decimal  :protein_g
  t.decimal  :fat_g
  t.decimal  :carbs_g
  t.string   :meal_type             # breakfast | lunch | dinner | snack
  t.string   :confidence            # high | medium | low  — SHOWN IN UI
  t.text     :assumptions           # "assumed 1 cup cooked rice" — SHOWN IN UI
  t.datetime :consumed_at, null: false
  t.timestamps
end
add_index :meal_entries, [:user_id, :consumed_at]
```

```ruby
create_table :weight_entries do |t|
  t.references :user, null: false
  t.decimal  :weight_kg, null: false
  t.string   :source                # manual | health_connect
  t.datetime :recorded_at, null: false
  t.timestamps
end

# Exercise is deferred (§8) but the table is cheap and the schema won't change.
create_table :exercise_entries do |t|
  t.references :user, null: false
  t.string   :activity_name
  t.integer  :duration_minutes
  t.decimal  :calories_burned
  t.string   :source                # met_estimate | manual | health_connect
  t.string   :external_id           # dedupe if Health Connect arrives later
  t.datetime :performed_at, null: false
  t.timestamps
end
add_index :exercise_entries, [:user_id, :external_id], unique: true, where: "external_id IS NOT NULL"
```

**`devices` is deleted.** Web Push works in a PWA on Android without it for now; add the table if and when we actually want notifications.

**`daily_logs` stays deleted.** Summing `meal_entries` for a date range at two users' volume is free. Compute on read.

---

## 6. Voice — the part we actually care about

The ask: **tap a mic button in the app, say a long rambling sentence, get it logged.** Not hands-free, not "Hey Google."

### Don't use the Web Speech API

`webkitSpeechRecognition` works in Chrome on Android and is free, which makes it the obvious first thing to reach for. It's the wrong tool here for one specific reason: **it stops on silence.** A pause mid-sentence ends the recognition session, `continuous` mode is unreliable across versions, and the failure mode is exactly the input we care about — *"a bowl of the chili from last night, maybe a cup and a half… plus a slice of sourdough with butter"* gets truncated at the ellipsis. Same objection to the Gboard mic: it works in a `<textarea>`, but it commits to the on-screen keyboard being up and it mangles food nouns.

### Use record → server-side STT → Claude

```
[mic button] → MediaRecorder (opus/webm) → POST /voice_entries
                                              ↓
                                         STT provider → transcript
                                              ↓
                                         AiChatTurnJob (§11) → log_meal
                                              ↓
                                         Turbo Stream → confirmation card
```

Why this shape:

- **No truncation.** You hold the button (or tap-to-start / tap-to-stop) and talk for as long as you want. Nothing ends the recording but you.
- **Better on food nouns.** Whisper-class models handle "tzatziki," "carnitas," "chana masala" far better than a general dictation engine — and you can bias them further (below).
- **Errors don't matter much.** The transcript goes to Claude, which is extremely tolerant of garbled input and can often repair it from context. What matters is *not losing the second half of the sentence*, which is exactly what the Web Speech API does.
- **You keep the audio.** When a parse comes out wrong, you can listen to what you actually said. Invaluable while tuning.

**Important:** the Anthropic API does not accept audio input, so STT is genuinely a separate step with a separate provider — you can't hand the clip to Claude directly.

### Choosing an STT provider

**Select on accuracy, not latency.** A few seconds of processing is acceptable (see UI below), which removes the usual reason to compromise — take the model that gets "chana masala" right over the one that's a second faster.

Start with a hosted API (one HTTP call, best accuracy, no ops). Whisper-class transcription runs on the order of **$0.006/minute** — verify current pricing, but the magnitude is what matters:

> 2 people × ~5 entries/day × ~15 seconds ≈ **2.5 min/day ≈ 75 min/month ≈ $0.45/month.**

Put it behind a one-method interface:

```ruby
# app/services/stt/client.rb
module Stt
  def self.transcribe(audio_io, hint: nil) = provider.transcribe(audio_io, hint:)
  def self.provider = @provider ||= Stt::Hosted.new   # swap for Stt::WhisperCpp later
end
```

Self-hosting `whisper.cpp` on the Linode is a viable phase-2 move, and the latency tolerance makes it *more* viable than it would otherwise be — a `base.en`/`small.en` model transcribes a 20-second clip in a few seconds on CPU, which is inside budget. But it's an optimization of $0.45/month, so do it only if you object to the third-party dependency, not to the bill.

**Bias the transcript with our own vocabulary.** Whisper-class APIs accept a prompt/vocabulary hint. Seed it from the `foods` table:

```ruby
hint = Food.joins(:meal_entries)
           .where(meal_entries: { user_id: user.id })
           .group(:id).order("COUNT(meal_entries.id) DESC")
           .limit(40).pluck(:name).join(", ")
```

Forty food names we actually eat, prepended to every transcription. Costs nothing, meaningfully improves the nouns that matter, and gets better the longer we use it.

### UI

**Tap to start, tap to stop.** Not press-and-hold — you're usually holding a pan, and hold-to-talk means the phone owns a hand for the whole utterance.

**A few seconds of processing is fine, as long as the app is visibly working.** This is a kitchen, not a trading floor. The requirement is *legible progress*, not speed — so don't paper over the wait with one long spinner. STT and Claude are separate steps, which gives us a real intermediate to show:

| State | Roughly | What the user sees |
|---|---|---|
| Recording | until you tap | Live waveform + elapsed timer — proof it's still listening |
| Uploading | <1s | Progress on the blob |
| Transcribing | ~1–2s | "Heard you…" |
| **Transcript lands** | ~2s | **The actual transcript text, rendered as your chat message** |
| Parsing | ~2–3s | Typing indicator under it |
| Logged | ~5s | Confirmation card + updated header totals |

The transcript landing at ~2s is the important one: from there it looks like an ordinary chat where you can see what you said and the assistant is replying. Nobody experiences that as a five-second wait.

Other notes:

- **Keep the transcript visible** under the parsed result permanently. Not to edit — to understand *why* it logged 400 calories of something weird three weeks later.
- Failed upload → keep the blob in IndexedDB, retry when back online (§10). Show the queued entry greyed out rather than throwing an error.
- The recording UI must survive a screen lock mid-utterance. Test this early; it's the most likely place the PWA behaves worse than a native app would.

---

## 7. Input hierarchy — cheapest and most accurate first

Every logging path is tried in this order. Most meals never reach the AI.

| # | Method | Accuracy | Notes |
|---|---|---|---|
| 1 | **Repeat-meal match** | As good as the original entry | Fuzzy-match against the *household's* last 90 days, then global `foods`. `pg_trgm` similarity, no embeddings. |
| 2 | **Barcode scan** | Ground truth | `BarcodeDetector` (native in Chrome on Android, on-device, free) + OpenFoodFacts. Zero inference. |
| 3 | **Voice / text** | Estimate | §6. The primary path for anything novel — and the one we're optimizing for. |
| 4 | **Nutrition-label OCR** | Ground truth | Photo of the label. Reading, not estimating. |
| 5 | **Photo identification** | Identifies *what*, not *how much* | Names the components, then asks about portion/prep. **Does not estimate macros unattended.** |
| 6 | **Manual entry** | Ours | Always available. |

Note the reorder from rev. 2: **repeat-meal matching moves to #1**, ahead of barcode. Two people eating from the same kitchen converge on a shared vocabulary fast — "the usual chicken bowl" should hit retrieval, not inference, within a couple of weeks. It's the single highest-leverage path in a household app.

**Photo is explicitly scoped to identification and matching.** "That looks like your usual chicken bowl — ~780 cal?" is retrieval. "That plate is 640 calories" is a guess we shouldn't make.

### Household affordance: log it for both of us

We eat the same dinner most nights. Any entry gets an **"also log for \<name\>"** affordance that copies it to another household member's day (`source: "copied"`, same macros, `consumed_at` = now). The assistant can do it too via `copy_to_household_member`. This halves the logging burden on ~40% of meals.

With one other member it renders as a single button naming them, which is the case we're building for. With more it becomes a short list. The *implementation* takes a target member either way (§16) — that's the whole point of not hardcoding "the other user."

---

## 8. Model selection

**Cost is no longer a design constraint.** At two people and ~120 AI-parsed entries/month between us — and falling, as paths 1–2 in §7 take over — the entire monthly bill lands between $2 and $9 depending on model. That's the difference between a coffee and two coffees. Pick the model that's best at the job.

| Path | Model | Rationale |
|---|---|---|
| Voice/text meal parse | `claude-opus-5` | $5/$25 per MTok. Best at ambiguous descriptions and garbled transcripts, which is exactly our input. ~$9/mo worst case. |
| Photo identification | `claude-opus-5` | Same model, one code path. High-resolution vision. |
| If you want to trim | `claude-sonnet-5` | $3/$15 ($2/$10 introductory through 2026-08-31). Saves ~$4/month. Make it a config value and stop thinking about it. |

Do **not** use Haiku here. It was the right call in rev. 2 because rev. 2 was paying for thousands of users; the reasoning doesn't survive the recast.

### Request configuration — corrected for current API behavior

Rev. 2 said *"no thinking on the parse path."* **That is now wrong, and specifically dangerous for this app:**

- **Thinking is on by default on Opus 5.** Omitting the `thinking` parameter runs adaptive thinking — it is not the "off" it was on earlier models.
- **Explicitly disabling thinking has a failure mode that bites tool-calling apps hardest:** with `thinking: {type: "disabled"}`, the model occasionally writes a tool call into its *visible text* instead of emitting a `tool_use` block. The turn completes normally, no error is raised, **and the meal is silently never logged.** In a chat loop the bogus text then pollutes later turns. It can also leak `<thinking>` tags into the response.

So: **leave adaptive thinking on and control cost with `effort` instead.**

```ruby
client.messages.create(
  model: "claude-opus-5",
  max_tokens: 8192,                            # thinking + text share this budget
  thinking: { type: "adaptive" },
  output_config: { effort: "low" },            # low | medium | high | xhigh | max
  system_: Ai::Prompts.meal_logging(user),
  messages: conversation.to_api_messages,
  tools: Ai::MealTools::ALL
)
```

- **`effort: "low"`** is the right starting point — this is structured extraction against a tight schema, not hard reasoning. Step up to `medium` if you see shallow parses. Do not try to make it cheaper by disabling thinking; that's the trap above.
- **`max_tokens: 8192`**, not rev. 2's 4096 and definitely not 1024. `max_tokens` caps thinking *plus* response text together, so a budget sized around the answer alone truncates mid-response.
- **Prompt caching now actually fires.** Rev. 2 correctly noted that Haiku 4.5's 4096-token minimum cacheable prefix meant caching would never engage on a ~1k-token system prompt + tool schema. **Opus 5's minimum is 512 tokens**, so the prefix caches. Put a `cache_control` breakpoint on the last system block and keep the system prompt byte-stable — no interpolated timestamps, no per-request IDs above the breakpoint.

---

## 9. Conversational logging

A single chat thread per user, tool-calling rather than one-shot JSON, corrections handled conversationally.

**Context is windowed.** Send the last ~10 turns plus a compact system-injected summary of today's totals. This is no longer a cost argument — at our volume it isn't one — it's a *quality* argument: a chat thread from three weeks ago is noise in the context, not context.

**The system prompt asks about cooking fat when it's material.** One question recovers ~120 kcal of otherwise-invisible error, and it's exactly the kind of high-information clarification worth blocking on.

```
You are a nutrition-logging assistant in a chat with the user. Figure out what
they ate and log it with the log_meal tool. Talk like a person, not a form.

The input is often a voice transcript, so expect run-on sentences, filler, self-
correction ("two eggs, no wait, three"), and mis-transcribed food names. Take the
last version of anything the user corrects mid-sentence. If a word looks like a
garbled food name, infer the most plausible dish rather than asking.

Ask at most one follow-up question per turn, and only when the answer would
materially change the estimate — portion size, or added fats (oil, butter,
dressing, sauce). Cooking fat is usually the largest unknown: a pan-fried
chicken breast is ~120 kcal more than a baked one, so ask when it's unclear and
the dish plausibly involves it. Don't ask about things you can reasonably assume.

If the user gives a vague portion ("some rice"), assume a typical serving, state
the assumption in `assumptions`, and let them correct it rather than blocking.

Set `confidence` honestly. It is shown to the user, and low-confidence entries
are rendered differently — an overconfident estimate is worse than a hedged one.

When context includes a prior similar entry, prefer matching it over
re-deriving from scratch. Consistency between entries matters more than
per-entry precision.

Once reasonably confident, call log_meal.
```

The paragraph on transcripts is new in rev. 3 and is doing real work — it's what lets §6's pipeline tolerate imperfect STT instead of round-tripping corrections through the user.

---

## 10. Interface

- **Primary screen is the chat.** Composer with a large mic button, a text field, and a camera button.
- **Persistent header strip**: calories consumed / target, macro bars. Tapping opens today's entries. No "remaining parses" counter — there's no quota.
- **Low-confidence entries render differently** — a hedged estimate visibly hedged. Tap to correct; correction goes through the same chat (`update_meal`), not a separate edit form.
- **"Also log for \<name\>"** on every entry (§7).
- **Trends tab**: weekly average intake, weight trend, calibrated TDEE. This is the "is it working" screen and the honest home for §2's framing. Show every household member on the same weight chart — it's a household, and it's motivating.
- **Offline capture**: service worker + IndexedDB. Queue the audio blob or text locally, sync when connectivity returns. Realistically a manual "retry" button covers 90% of this; build the full queue only if the retry button annoys us.
- Technically: Turbo Streams append messages; the AI turn runs in a Solid Queue job so the UI shows a typing indicator rather than blocking.

### PWA specifics

- `manifest.json` with `display: "standalone"`, both icon sizes, `theme_color`, `start_url: "/"`.
- Service worker registered on first load; Chrome on Android then offers **Install app**, producing a WebAPK with its own app-drawer and task-switcher entry.
- `apple-touch-icon` is irrelevant here. Skip it.

---

## 11. Exercise & weight

**Weight is manual, and it ships early.** A number field and a "log weight" button. Calibration (§12) needs history, so start collecting before it's useful — that's the whole reason it's early despite being boring.

**Exercise is deferred.** Health Connect has no web API, so auto-import requires the native shell (§3). Until then:

- A **MET-value table** for activity described conversationally — deterministic, free, no AI cost. `log_exercise` carries `duration_minutes` and `intensity`, which is everything a MET lookup needs. Keep the tool so chat stays the interface; compute the burn in Ruby.
- Honestly: for a deficit-tracking app, exercise burn is the *second* noisiest number after meal estimates. Not having it on day one is fine, and §12 backs out the aggregate anyway from weight trend.

---

## 12. Calibration — making the imprecision not matter

The design's answer to §2. Random logging error averages out over weeks; systematic error can be solved for.

Given daily logged intake and daily weight, over a 2–3 week window you can estimate actual **TDEE** and a **personal logging bias** (`logging_bias_factor`). If someone consistently under-logs by 15%, you don't fix the estimates — you shift their target down 15% and the system converges anyway.

A weekly job, per user:

1. Fit a trend line to `weight_entries` (7-day rolling average, not raw daily readings).
2. Combine with logged intake to solve for `estimated_tdee`.
3. Derive `logging_bias_factor` from the residual.
4. Adjust `daily_calorie_target` toward the goal rate.

**With n=2, add a manual override.** Expose `logging_bias_factor` in a settings screen. If the fit looks wrong you can just look at the chart and type a better number — a luxury a real product doesn't get, and it means the automated fit doesn't have to be robust, only roughly right.

**UI framing that follows:** the daily number is a working figure; the *weekly* average plus weight trend is the primary chart. Say plainly that day-to-day numbers are approximate and the trend is what matters.

---

## 13. Longevity — the thing that actually threatens this

Rev. 2's risk section was about distribution and churn. Neither applies. The real failure modes for personal software are: **the box dies, or you stop caring and it quietly rots.**

- **Nightly `pg_dump` off the box.** To object storage, or `rsync` to a home machine, or both. Retain 30 days. This is the single most important operational line in the doc — it protects two years of accumulated `foods` and `meal_entries`, which is the only genuinely irreplaceable thing here.
- **CSV export** for both users, one button. Not a premium feature — an exit hatch. If we abandon this, the data should outlive it.
- **Pin the dependencies and don't chase upgrades.** Rails 8 LTS-ish behavior, `bundle update` on a schedule you choose, not on notification.
- **A `/up` healthcheck and one uptime ping.** You want to know it's down before you're standing in a restaurant discovering it.

---

## 14. Build Phases

Ordered so the app is on both phones and genuinely usable as early as possible — for two users, real daily use is the only meaningful feedback loop.

1. **Core.** Rails 8 skeleton, built-in auth, two seeded users, `users.timezone`, `meal_entries`, manual entry, day totals, header strip. **Deploy to the subdomain immediately** and put it on both phones — you'll learn more in three days of use than three days of design.
2. **PWA shell.** Manifest, service worker, icons, standalone display. Install on both phones. From here, `git push` is the release process.
3. **Conversational logging.** Chat UI, tool loop (§16), context windowing, Opus 5, `Conversation`/`Message`. Text-only.
4. **Voice.** `MediaRecorder` → `/voice_entries` → STT → the phase-3 pipeline. Vocabulary hint from `foods`. **This is the phase that makes it the app we wanted.**
5. **Repeat-meal matching + "also log for".** `pg_trgm` against the household's history. The two highest-leverage friction cuts, and both are zero-AI-cost.
6. **Barcode.** `BarcodeDetector` + OpenFoodFacts.
7. **Weight logging + trends tab.**
8. **Calibration.** Weekly TDEE/bias job, manual override.
9. **Backups + CSV export** (§13). Arguably belongs at step 2 — do it whenever it starts to feel scary.
10. **Optional, only if missed:** photo identification; nutrition-label OCR; Hotwire Native Android shell for Health Connect and a widget.

No gate, no metrics, no go/no-go. The success criterion is "do we still use it in a month," and we'll know without instrumenting it.

---

## 15. Tool Schemas

```ruby
# app/services/ai/meal_tools.rb
module Ai
  module MealTools
    LOG_MEAL = {
      name: "log_meal",
      description: "Log a meal or food item the user ate, with estimated nutrition. " \
                   "Call this once you're reasonably confident — don't wait for certainty. " \
                   "Returns the created entry's ID and the user's running day total.",
      input_schema: {
        type: "object",
        properties: {
          food_name:      { type: "string", description: "Short human-readable name, e.g. 'chicken burrito bowl'" },
          quantity_grams: { type: "number", description: "Estimated total weight in grams" },
          calories:       { type: "number" },
          protein_g:      { type: "number" },
          fat_g:          { type: "number" },
          carbs_g:        { type: "number" },
          meal_type:      { type: "string", enum: %w[breakfast lunch dinner snack] },
          confidence:     { type: "string", enum: %w[high medium low],
                            description: "Shown to the user. Be honest — 'low' is fine and useful." },
          assumptions:    { type: "string", description: "Plain-language note on assumptions, shown to the user" }
        },
        required: %w[food_name quantity_grams calories protein_g fat_g carbs_g meal_type confidence]
      }
    }.freeze

    UPDATE_MEAL = {
      name: "update_meal",
      description: "Correct the most recently logged meal (e.g. 'actually make that double chicken'). " \
                   "Use the meal_entry_id returned by log_meal in this conversation.",
      input_schema: {
        type: "object",
        properties: {
          meal_entry_id:  { type: "integer", description: "ID returned by a previous log_meal call" },
          food_name:      { type: "string" },
          quantity_grams: { type: "number" },
          calories:       { type: "number" },
          protein_g:      { type: "number" },
          fat_g:          { type: "number" },
          carbs_g:        { type: "number" },
          confidence:     { type: "string", enum: %w[high medium low] },
          assumptions:    { type: "string" }
        },
        required: %w[meal_entry_id calories protein_g fat_g carbs_g]
      }
    }.freeze

    # New in rev. 3 — the household affordance from §7. Takes an explicit target, because
    # "the other member" stops being well-defined the moment there are three of them. The
    # system prompt lists the household's member names, so the model has them to hand.
    COPY_TO_HOUSEHOLD_MEMBER = {
      name: "copy_to_household_member",
      description: "Copy an already-logged meal to another household member's log, for when " \
                   "more than one person ate the same thing. Use when the user says something " \
                   "like 'we both had that' or 'log that for her too'.",
      input_schema: {
        type: "object",
        properties: {
          meal_entry_id: { type: "integer", description: "ID of the entry to copy" },
          member_name:   { type: "string",
                           description: "Display name of the household member to copy to, " \
                                        "as listed in the system prompt. Omit only if the " \
                                        "household has exactly one other member." }
        },
        required: %w[meal_entry_id]
      }
    }.freeze

    LOG_EXERCISE = {
      name: "log_exercise",
      description: "Log an activity the user described. Calorie burn is computed server-side " \
                   "from a MET table — supply activity, duration, and intensity; do not " \
                   "estimate calories yourself.",
      input_schema: {
        type: "object",
        properties: {
          activity_name:    { type: "string", description: "e.g. 'running', 'weightlifting'" },
          duration_minutes: { type: "integer" },
          intensity:        { type: "string", enum: %w[light moderate vigorous] }
        },
        required: %w[activity_name duration_minutes intensity]
      }
    }.freeze

    ALL = [LOG_MEAL, UPDATE_MEAL, COPY_TO_HOUSEHOLD_MEMBER, LOG_EXERCISE].freeze
  end
end
```

---

## 16. The turn job and dispatcher

> A `tool_use` block **must** be answered with a `tool_result` in a follow-up request, or the model never gets to produce the confirmation text. It also needs the returned `meal_entry_id` for `update_meal` and `copy_to_household_member` to work at all.

```ruby
# app/jobs/ai_chat_turn_job.rb
class AiChatTurnJob < ApplicationJob
  MAX_ITERATIONS = 5

  def perform(conversation:, user_message:)
    user   = conversation.user
    client = Ai.client   # single shared key — no per-user routing

    conversation.messages.create!(role: "user", content: [{ type: "text", text: user_message }])

    MAX_ITERATIONS.times do
      response = client.messages.create(
        model: Rails.configuration.x.ai_model,   # "claude-opus-5"
        max_tokens: 8192,                        # thinking + text share this — see §8
        thinking: { type: "adaptive" },
        output_config: { effort: "low" },
        system_: Ai::Prompts.meal_logging(user), # trailing underscore is the Ruby SDK's
        messages: conversation.to_api_messages,  # windowed — see §9
        tools: Ai::MealTools::ALL
      )

      conversation.messages.create!(role: "assistant", content: response.content)
      Ai::Broadcaster.stream_text(conversation, response)

      break unless response.stop_reason == :tool_use   # Symbol in the Ruby SDK

      # Execute every tool_use block and return ALL results in ONE user message.
      results = response.content.filter_map do |block|
        next unless block.type == :tool_use
        Ai::ToolHandlers.dispatch(user:, conversation:, tool_use: block)
      end

      conversation.messages.create!(role: "user", content: results)
    end
  end
end
```

The Ruby SDK's `client.beta.messages.tool_runner` will drive this loop for you; the manual form is shown because we need control over persistence and Turbo broadcasting between turns.

```ruby
# app/services/ai/tool_handlers.rb
module Ai
  module ToolHandlers
    MEAL_ATTRS = %w[quantity_grams calories protein_g fat_g carbs_g
                    meal_type confidence assumptions].freeze

    def self.dispatch(user:, conversation:, tool_use:)
      payload =
        case tool_use.name
        when "log_meal"                 then log_meal(user, conversation, tool_use.input)
        when "update_meal"              then update_meal(user, tool_use.input)
        when "copy_to_household_member" then copy_to_member(user, tool_use.input)
        when "log_exercise"             then log_exercise(user, tool_use.input)
        else { error: "unknown tool #{tool_use.name}" }
        end

      { type: "tool_result", tool_use_id: tool_use.id, content: payload.to_json }
    rescue => e
      Rails.logger.error("tool #{tool_use.name} failed: #{e.class}: #{e.message}")
      { type: "tool_result", tool_use_id: tool_use.id, content: e.message, is_error: true }
    end

    def self.log_meal(user, conversation, input)
      entry = user.meal_entries.create!(
        # Whitelisted: tool input is model output and must never be mass-assigned.
        input.slice(*MEAL_ATTRS).merge(
          food: Food.match_or_create(input["food_name"]),   # §7 path 1, shared table
          raw_input: conversation.last_user_text,           # the transcript, for voice
          source: conversation.last_input_source,           # voice | text
          consumed_at: Time.current
        )
      )
      conversation.update!(last_meal_entry: entry)

      # Returning the ID is what makes update_meal and copy_to_household_member possible.
      { logged: true, meal_entry_id: entry.id, day_total: user.day_totals(Time.current) }
    end

    def self.update_meal(user, input)
      entry = user.meal_entries.find(input["meal_entry_id"])   # user-scoped
      entry.update!(input.slice(*MEAL_ATTRS))
      { updated: true, meal_entry_id: entry.id, day_total: user.day_totals(Time.current) }
    end

    def self.copy_to_member(user, input)
      entry  = user.meal_entries.find(input["meal_entry_id"])
      target = resolve_member(user, input["member_name"])
      copy   = target.meal_entries.create!(
        entry.slice(*MEAL_ATTRS, "food_id", "raw_input").merge(
          source: "copied", consumed_at: Time.current
        )
      )
      { copied: true, to: target.name, meal_entry_id: copy.id }
    end

    # Resolve by name when given one. With a single other member, allow the model to omit
    # it — that's the common case and asking would be pointless. With several, insist,
    # because guessing whose day to modify is worse than one clarifying question.
    def self.resolve_member(user, name)
      members = user.household_members

      if name.present?
        user.household_member_named(name) ||
          raise(ArgumentError, "No household member named #{name}. Members: #{members.map(&:name).join(', ')}")
      elsif members.one?
        members.first
      else
        raise ArgumentError, "Which member? One of: #{members.map(&:name).join(', ')}"
      end
    end

    def self.log_exercise(user, input)
      burn = Met::Table.calories_for(
        activity: input["activity_name"],
        intensity: input["intensity"],
        minutes: input["duration_minutes"],
        weight_kg: user.latest_weight_kg
      )
      entry = user.exercise_entries.create!(
        activity_name: input["activity_name"],
        duration_minutes: input["duration_minutes"],
        calories_burned: burn,
        source: "met_estimate",
        performed_at: Time.current
      )
      { logged: true, exercise_entry_id: entry.id, calories_burned: burn }
    end
  end
end
```

The `ArgumentError`s in `resolve_member` become `is_error: true` tool results via `dispatch`'s rescue, which means the model reads the failure and can ask the user which member it meant. That's the right shape: an ambiguous copy target is a question, not a crash.

---

## 17. Open Questions

- **Domain / subdomain name.** Subdomain on the existing Linode is the plan; needs a name.
- **STT provider.** Compare two or three on a real 20-second clip of one of us rambling about dinner, and pick on **transcription accuracy of food nouns** — latency is not a tiebreaker (§6).
- **Does `pg_trgm` suffice for repeat-meal matching?** Start with trigram plus a recency window across the household; reach for `pgvector` only if match rates are poor in real use.
- **Minimum viable calibration window.** §12 assumes 2–3 weeks of weight data. Needs a graceful "not enough data yet" state rather than a garbage TDEE.

### Resolved in rev. 3

- ~~Web vs. mobile~~ → PWA on Android, native shell as a cheap later escape hatch (§3).
- ~~Which STT~~ → not Web Speech API; record → server-side STT (§6).
- ~~Tap-to-stop vs. hold-to-talk~~ → tap to start, tap to stop (§6).
- ~~Is a ~5s parse wait a problem?~~ → no. The constraint is legible progress, not speed: stage the feedback so the transcript lands at ~2s and the parsed card at ~5s (§6). This also frees the STT choice to optimize for accuracy.
- ~~Devise + confirmable~~ → Rails 8 built-in auth, two seeded users, no signup (§4).
- ~~Model tier as product tier~~ → no tiers; Opus 5 everywhere (§8).
- ~~Disable thinking on the parse path~~ → **no**; adaptive thinking + `effort: "low"` (§8).
- ~~Prompt caching won't fire~~ → it will, on Opus 5's 512-token minimum (§8).
- ~~Monetization, IAP, BYO-AI, the D30 gate~~ → deleted.
