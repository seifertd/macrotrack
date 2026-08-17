# MacroTrack — Design Doc (rev. 2)

AI-assisted calorie/macro tracker. Rails 8 backend, **mobile-first** via Hotwire Native (iOS + Android). Freemium with a BYO-AI add-on.

> **What changed in rev. 2:** mobile is now the primary target, not the web; photo input is rescoped from *estimation* to *identification and matching*; barcode and repeat-meal matching become the accuracy story; exercise comes from HealthKit/Health Connect rather than AI; the model tier becomes the product tier; billing moves from Stripe to IAP; and the tool-calling loop in §11 is corrected (rev. 1's version never returned `tool_result`, so it could not work).

---

## 1. Goals

- Kill the "look up grams of protein/fat/carbs and convert to servings" friction that kills adherence to apps like Easy Fit Pro.
- Logging should take **under five seconds** for a repeat meal and under fifteen for a novel one.
- Exercise should be **read from the phone**, not typed.
- Public multi-user app on a real domain, with a monetization lever we can flip on later.
- Power users can bring their own AI API key.

**Explicit non-goal: absolute accuracy.** See §2 — we are not competing on precision, and pretending otherwise sets us up to be measurably wrong.

---

## 2. Positioning — the accuracy problem, stated honestly

This section drives most of the design decisions below, so it comes first.

**You cannot determine macros from a photo, and largely can't from a description either.** A tablespoon of olive oil is ~120 kcal and 14g of fat, and it is invisible once absorbed into a stir-fry. Sautéed vegetables look identical to steamed. Restaurant kitchens use far more butter than home cooks and you can't see any of it. Depth and density are unrecoverable from a 2D image (a bowl of rice is 150g or 350g depending on the bowl). Whole vs. skim milk in a latte, full-fat vs. 0% yogurt — visually identical.

A single meal estimate can be off by **300–500 kcal in either direction**. If the user's target deficit is 500 kcal/day, the signal is inside the noise.

This is not a model capability gap that a better model fixes. The information is not in the input. Trained dietitians estimating portions from photographs have substantial error rates for the same reason.

**Three consequences:**

1. **Never market accuracy.** Market friction. The accurate alternative — kitchen scale plus USDA lookups — has near-zero adherence, which is the entire premise of §1.
2. **Prefer ground truth wherever it exists.** Barcode and nutrition-label OCR are *reading*, not estimating. Matching against a meal the user already logged is *retrieval*, not estimating. Both are more accurate and cheaper than inference. See §6.
3. **Make the imprecision not matter, statistically.** High-variance error can't be calibrated away per-meal, but it averages out over weeks — and systematic error can be backed out from weight trend. See §9. Daily numbers are noise; weekly trend plus weight is signal, and the UI should say so.

Surface uncertainty rather than hiding it: the `confidence` and `assumptions` fields from the tool schema are shown in the UI, and correcting an entry is one tap.

---

## 3. Stack

- **Rails 8**, Postgres (with `pg_trgm` for food matching), Hotwire (Turbo + Stimulus).
- **Hotwire Native** shells for iOS (Swift) and Android (Kotlin) — thin native wrappers around the existing Turbo-driven screens, with selected screens replaced natively.
- **Devise** for auth, `confirmable` enabled (public app + shared API key = abuse vector).
- **Solid Queue** for background jobs — every AI turn runs in a job.
- **RevenueCat** (or StoreKit 2 + Play Billing directly) for subscriptions. **Not Stripe** — see §10.
- Deploy: Linode alongside chord-practice.com via Kamal.

### Why Hotwire Native and not React Native / Flutter

| Approach | Rails work discarded | New codebases | Time to first TestFlight |
|---|---|---|---|
| **Hotwire Native** | ~none | 2 thin shells | days |
| React Native / Expo | all view code; Rails → JSON API | 1 + API layer | weeks |
| Flutter | same, plus a new language | 1 + API layer | weeks |

Anything else means writing a JSON API, token auth, a client-side state layer, and a streaming protocol — all of which Hotwire currently provides. Server-rendered screens also still deploy instantly with `git push`; only shell changes need app review.

**The one screen that must be native from day one is the chat composer.** Keyboard avoidance, autocorrect, the mic button, and scroll-to-bottom are exactly where a webview feels wrong. The message list stays Turbo.

---

## 4. Data Model

```ruby
create_table :users do |t|
  t.string   :email, null: false
  t.string   :encrypted_password, null: false
  t.string   :timezone, null: false, default: "UTC"   # REQUIRED — see note below
  t.integer  :daily_calorie_target, default: 2000
  t.string   :subscription_tier, default: "free"      # free | pro
  t.boolean  :byo_enabled, default: false
  t.integer  :ai_parses_this_period, default: 0       # counts MEALS, not API calls
  t.datetime :period_started_at
  # calibration outputs (§9)
  t.decimal  :estimated_tdee
  t.decimal  :logging_bias_factor, default: 1.0
  t.datetime :calibrated_at
  t.timestamps
end
```

> **Timezone is not optional.** `daily_logs` in rev. 1 keyed on a date while `consumed_at` was a UTC datetime, with no user timezone anywhere. For a calorie tracker "what day was this" *is* the product — an 11pm snack on the East Coast would land on tomorrow's total. Every daily rollup goes through `user.timezone`.

```ruby
# conversations + messages — MISSING from rev. 1, but §11's code calls four
# methods on a Conversation. One conversation per user; messages are windowed.
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
# foods — canonical/cached items. Rev. 1 defined this table and never wrote to
# it. It is now load-bearing: it is how repeat meals avoid inference entirely.
create_table :foods do |t|
  t.string  :name, null: false
  t.string  :source                # usda | openfoodfacts | ai_estimate | user_custom
  t.string  :barcode               # nil unless scanned
  t.decimal :calories_per_100g
  t.decimal :protein_per_100g
  t.decimal :fat_per_100g
  t.decimal :carbs_per_100g
  t.jsonb   :raw_ai_response       # debugging only; never user free text (privacy — shared table)
  t.timestamps
end
add_index :foods, :barcode, unique: true, where: "barcode IS NOT NULL"
add_index :foods, :name, using: :gin, opclass: :gin_trgm_ops
```

```ruby
create_table :meal_entries do |t|
  t.references :user, null: false
  t.references :food, null: true
  t.string   :raw_input             # what the user actually typed/said
  t.string   :source, null: false   # barcode | matched | photo | text | manual
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
create_table :exercise_entries do |t|
  t.references :user, null: false
  t.string   :activity_name
  t.integer  :duration_minutes
  t.decimal  :calories_burned
  t.string   :source                # health_kit | health_connect | met_estimate | manual
  t.string   :external_id           # HKWorkout UUID — dedupe on re-sync
  t.datetime :performed_at, null: false
  t.timestamps
end
add_index :exercise_entries, [:user_id, :external_id], unique: true, where: "external_id IS NOT NULL"
```

```ruby
# weight_entries — new. This is the calibration input (§9), not a vanity metric.
create_table :weight_entries do |t|
  t.references :user, null: false
  t.decimal  :weight_kg, null: false
  t.string   :source                # health_kit | health_connect | manual
  t.datetime :recorded_at, null: false
  t.timestamps
end

# devices — push tokens
create_table :devices do |t|
  t.references :user, null: false
  t.string   :platform, null: false   # ios | android
  t.string   :token, null: false
  t.datetime :last_seen_at
  t.timestamps
end
add_index :devices, :token, unique: true
```

**`daily_logs` is deleted.** Rev. 1 had a materialized rollup with no invalidation story, mutated out from under it by `update_meal`. At one user's daily volume, summing `meal_entries` for a date range is trivial. Compute on read; add the cache back only if a widget query actually proves slow.

---

## 5. Model selection

| Path | Model | Rationale |
|---|---|---|
| Text/voice meal parse | `claude-haiku-4-5` | $1/$5 per MTok. This is structured extraction against a tight tool schema, not hard reasoning. |
| Photo identification | `claude-sonnet-5` | $3/$15. Better vision, high-resolution tier. Only fires on photo input. |
| BYO key | user's choice | `claude-opus-5`, Sonnet 5, whatever they configure. |

Rev. 1's example `claude-sonnet-4-6` is a previous-generation ID. Current IDs are `claude-opus-5`, `claude-sonnet-5`, `claude-haiku-4-5` — no date suffixes.

**Request configuration:**

- **No thinking on the parse path.** Extraction doesn't need it. On Haiku 4.5 omit the `thinking` param and do **not** pass `output_config.effort` (Haiku 4.5 errors on it). On Sonnet 5, thinking is *on by default* — pass `thinking: { type: "disabled" }` explicitly for the photo path.
- **`max_tokens: 4096`**, not 1024. Rev. 1's 1024 would truncate — on models where thinking is on by default, `max_tokens` caps thinking *plus* response text.
- **Prompt caching:** the system prompt + tool schemas are ~1k tokens. Haiku 4.5's minimum cacheable prefix is 4096 tokens, so caching **will not fire** on the Haiku path. Don't build around it. Sonnet 5's minimum is 1024, so the photo path can cache.

> Model choice is worth roughly $600/year at realistic scale (§10). It is not the constraint. Pick the cheap model, make it a config value, and stop thinking about it.

---

## 6. Input hierarchy — cheapest and most accurate first

Every logging path is tried in this order. Most meals never reach the AI.

| # | Method | Accuracy | AI cost | Notes |
|---|---|---|---|---|
| 1 | **Barcode scan** | Ground truth | **$0** | Camera + OpenFoodFacts (free, open) / USDA FoodData Central. Zero inference. |
| 2 | **Repeat-meal match** | As good as the original entry | **$0** | Fuzzy-match against *this user's* last 90 days first, then global `foods`. `pg_trgm` similarity, no embeddings needed. |
| 3 | **Nutrition-label OCR** | Ground truth | Low | Photo of the label. Reading, not estimating. |
| 4 | **Photo identification** | Identifies *what*, not *how much* | Medium | Model names the components, then asks about portion/prep. **Does not estimate macros unattended.** |
| 5 | **Conversational text/voice** | Estimate | Medium | The rev. 1 flow. Still the fallback for anything novel. |
| 6 | **Manual entry** | User's own | $0 | Always available. Required for App Store Guideline 4.2 (§10). |

Most people eat roughly thirty distinct things. Paths 1 and 2 should cover the large majority of entries once a user has a couple of weeks of history — which is what makes the unit economics work *and* what makes the numbers consistent enough for §9's calibration to function.

**Photo is explicitly scoped to identification and matching.** "That looks like your usual chicken bowl — ~780 cal?" is retrieval. "That plate is 640 calories" is a guess we shouldn't make.

**Voice** uses native `SFSpeechRecognizer` / Android `SpeechRecognizer` — on-device, free, offline, and far better than the Web Speech API (which is Chrome/Edge-only and was rev. 1's plan).

---

## 7. Conversational logging

Unchanged in spirit from rev. 1 — a single chat thread, tool-calling rather than one-shot JSON, corrections handled conversationally. Three changes:

**Context is windowed, not infinite.** Rev. 1 sent the entire thread every turn (§7 "persistent chat" + `conversation.to_api_messages`). By meal 30 you're resending a month of history on every request — the single largest cost driver in the design, larger than model choice. Send the last N turns (start with 10) plus a compact system-injected summary of today's totals.

**The system prompt asks about cooking fat when it's material.** One question recovers ~120 kcal of otherwise-invisible error, and it's exactly the kind of high-information clarification worth blocking on.

```
You are a nutrition-logging assistant in a chat with the user. Figure out what
they ate and log it with the log_meal tool. Talk like a person, not a form.

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

**Key routing order** (unchanged from rev. 1, but the counter changed):

1. User's own `ai_credentials` if present and active.
2. App's shared key, gated on `ai_parses_this_period` vs. tier limit.
3. Limit exceeded and no BYO key → the assistant says so *in the chat*, and points at barcode/manual entry, which remain unlimited.

The counter increments **per meal logged**, not per API call — a chatty clarification shouldn't cost the user their quota.

---

## 8. Exercise — read it, don't type it

**HealthKit (iOS) / Health Connect (Android) replace most of `log_exercise`.** Don't ask someone to type "ran 3 miles" when their Watch already recorded it with a real heart-rate-derived burn. Read workouts, steps, and active energy; dedupe on `external_id`.

Also **write nutrition back** to Health. This is a real retention hook — the app plays nicely with everything else on the phone.

For activity described conversationally but not captured by a device, use a **MET-value table** — deterministic, free, no AI cost. `log_exercise` already carries `duration_minutes` and `intensity`, which is everything a MET lookup needs. Keep the tool so chat stays the interface; compute the burn in Ruby.

This closes rev. 1's §10 open question.

---

## 9. Calibration — making the imprecision not matter

The design's answer to §2. Random logging error averages out over weeks; systematic error can be solved for.

Given daily logged intake and daily weight, over a 2–3 week window you can estimate the user's **actual TDEE** and their **personal logging bias** (`logging_bias_factor`). If someone consistently under-logs by 15%, you don't need to fix the estimates — you shift their target down 15% and the system converges anyway.

A weekly job:

1. Fit a trend line to `weight_entries` (7-day rolling average, not raw daily readings).
2. Combine with logged intake + Health-derived expenditure to solve for `estimated_tdee`.
3. Derive `logging_bias_factor` from the residual.
4. Adjust `daily_calorie_target` toward the user's goal rate.

**UI framing that follows from this:** show the daily number as a working figure, and make the *weekly* average plus the weight trend the primary chart. Say plainly that day-to-day numbers are approximate and the trend is what matters. This is honest, it's correct, and it defuses the accuracy objection rather than papering over it.

Weight logging must ship **before** it feels useful, because calibration needs history. Get it in early and let Health/a smart scale populate it for free.

---

## 10. Monetization

### The economics

Net revenue at $4.99/mo or $34.99/yr, 15% store commission (Small Business Program, under $1M/yr), 60/40 annual/monthly mix ≈ **$3.19 per paying user per month**.

Against AI cost for an engaged tracker at ~60 entries/month — and note that paths 1–2 in §6 drive this *down* over a user's lifetime:

| Pro model | AI cost/mo | Net rev | Margin |
|---|---|---|---|
| Haiku 4.5 | $0.90 | $3.19 | **+$2.29** |
| Sonnet 5 | $2.70 | $3.19 | +$0.49 |
| Opus 5 | $4.50 | $3.19 | **−$1.31** |

Rev. 1's implied $3–5 price with an unlimited premium model was **structurally unprofitable on the average paying customer**, not just heavy ones. Hence Haiku as the Pro default, Sonnet only on the photo path, and $4.99 rather than $3.99. (For context, this is still cheap for the category — MyFitnessPal Premium is ~$20/mo, MacroFactor ~$12/mo.)

Subtract free-tier drag (~$0.20/mo per active free user, roughly 3 per paying user) → **contribution margin ≈ $1.20–1.50 per paying subscriber per month.**

### Tiers

| Tier | Price | Includes |
|---|---|---|
| **Free** | — | Unlimited barcode, manual entry, repeat-meal matching, Health import. **15 AI parses/month.** |
| **Pro** | $4.99/mo or $34.99/yr | Unlimited AI parsing (Haiku), photo input (Sonnet), trends, CSV export, widgets. |
| **BYO add-on** | $1.99/mo | Everything in Pro; your key, your Anthropic bill. |

Two deliberate changes from rev. 1:

**The free tier leans on the zero-cost paths.** Barcode, manual, matching, and Health import cost nothing and make the free app genuinely useful — which also satisfies App Store Guideline 4.2 (Minimum Functionality). Meter only the AI, at 15/month rather than 30.

**BYO-AI is a discounted add-on, not free.** Rev. 1 gave it away, but the target audience it names — "a Ruby/AI hobbyist audience" — is *precisely* the segment with the highest willingness to pay for a well-made indie tool. Giving them a free forever pass hands away the best customers. It's also a tiny market: the intersection of "tracks macros," "holds an Anthropic API key," and "will paste it into a third-party app" is low thousands globally, so it's not a growth channel either. $1.99 keeps the differentiator and stops paying for it with the highest-value cohort.

### Billing mechanics

**Stripe does not work here.** Apple Guideline 3.1.1 requires IAP for digital subscriptions unlocking in-app functionality; Google Play is equivalent. Use StoreKit 2 + Play Billing, or RevenueCat to make cross-platform subscription state one integration instead of three.

The external-link landscape has been moving — the 2025 US ruling in *Epic v. Apple* forced Apple to permit external purchase links without commission on the US storefront, and the EU's DMA opened parallel paths. **Verify current guidelines before building the billing flow.** Budget for IAP as the baseline and treat external checkout as an optimization.

**BYO key entry on a phone is a funnel killer** — nobody types a 108-character key on a touch keyboard. Support paste-from-clipboard, QR from desktop, and an email-yourself-a-link flow. Keep the key server-side (Rails `encrypts`) rather than on-device: on-device means calls go phone→Anthropic directly, losing server-side conversation state and the shared `foods` cache. Say so explicitly in the UI.

### Cost transparency

- Remaining free parses shown in the chat header, not buried in settings.
- The assistant says it in-chat when the limit is near.
- BYO settings state plainly: "your key, your Anthropic bill, roughly $0.01–0.05 per meal depending on model." Anyone technical enough to bring a key will not object to being told the number, and everyone resents finding it out later.

### What this actually earns

At ~$1.35 contribution margin per subscriber per month, and 10%/month churn:

| Target net | Paying subs | Cumulative installs @ 2% conv. | New subs/mo to hold flat |
|---|---|---|---|
| $250/mo | ~185 | ~9,000 | ~19 |
| $1,000/mo | ~740 | ~37,000 | ~74 |
| $5,000/mo | ~3,700 | ~185,000 | ~370 |

The right-hand column is the one that matters — churn makes this a treadmill, not a staircase. Fitness apps also see 3–5× signups in January and mass churn in February–March; do not extrapolate a January cohort.

**Distribution is the constraint, not AI cost or model choice.** Going from 3,000 to 30,000 installs is worth ~$10,000/yr; optimizing the model is worth ~$600. Budget attention accordingly.

---

## 11. Interface

- **Primary screen is the chat.** Native composer (text + mic + camera button); Turbo-rendered message list.
- **Persistent header strip**: calories consumed / target, macro bars, remaining free parses. Tapping opens today's entries.
- **Low-confidence entries render differently** — a hedged estimate visibly hedged. Tap to correct; correction goes through the same chat (`update_meal`), not a separate edit form.
- **Trends tab**: weekly average intake, weight trend, calibrated TDEE. This is the "is it working" screen and the honest home for §9's framing.
- **Widgets / Live Activities**: remaining calories at a glance. Disproportionately valuable for an adherence product.
- **App Intents / Shortcuts**: "Hey Siri, log a banana."
- **Offline capture**: queue entries locally, sync and parse when connectivity returns.
- Technically: Turbo Streams append messages; the AI turn runs in a background job so the UI shows a typing indicator rather than blocking.

---

## 12. Build Phases

Reordered around §2 and §6 — the cheap, accurate paths ship before the expensive, imprecise ones.

1. **Core** — Rails skeleton, Devise (`confirmable`), models above, `users.timezone`, manual entry, daily totals, running-total header. Web only; this is the dev loop.
2. **Conversational logging** — chat UI, corrected tool loop (§13), context windowing, Haiku 4.5, `Conversation`/`Message`, tier gate live from day one (stubbed billing, real counter).
3. **Hotwire Native shells** — iOS + Android, native composer, push registration + `devices`, deep links, `/api/minimum_version` gating.
4. **Barcode + label OCR + repeat-meal matching** — the accuracy story, and mostly zero AI cost.
5. **Health integration + weight logging** — read workouts/energy, write nutrition, populate `weight_entries`.
6. **Photo input** — identification and matching only (§6 path 4).
7. **Calibration** — weekly TDEE/bias job, trends tab.
8. ⛔ **Gate: measure activation → D30 retention before proceeding.**
9. **Monetization** — StoreKit 2 / Play Billing / RevenueCat, tiering.
10. **BYO-AI, widgets, App Intents, CSV export.**

### On the gate

Ship phases 1–7 free with BYO-key-optional and measure one number: **do users who log three meals still log at 30 days?** If yes, monetization is a solvable second problem. If no — the common outcome in this category — no pricing structure saves it, and you'll have learned that for the price of an Apple Developer account instead of six months of billing infrastructure.

Realistic Year 1 outcomes, organic launch, no paid acquisition:

| | Pessimistic | Base | Optimistic |
|---|---|---|---|
| Installs | 500 | 3,000 | 50,000 |
| Steady-state subs | ~4 | ~30 | ~900 |
| **Net Y1** | **≈ −$60** | **≈ +$660** | **≈ +$24,000** |

Pessimistic is the modal outcome and is not a failure — it's a tool you use daily and a portfolio piece. Deciding up front which outcome would still be worth the build is worth doing before phase 1.

---

## 13. Tool Schemas and Call Path

### Tool definitions

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

    LOG_EXERCISE = {
      name: "log_exercise",
      description: "Log an activity the user described that their phone did NOT already record. " \
                   "Calorie burn is computed server-side from a MET table — supply activity, " \
                   "duration, and intensity; do not estimate calories yourself.",
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

    ALL = [LOG_MEAL, UPDATE_MEAL, LOG_EXERCISE].freeze
  end
end
```

Note `log_exercise` no longer accepts `calories_burned` — §8 computes it deterministically.

### The turn job — corrected

> **Rev. 1's version was broken.** It made one API call, dispatched the tool, and stopped. But a `tool_use` block **must** be answered with a `tool_result` in a follow-up request, or the model never gets to produce the confirmation text that rev. 1's own §4 turn-flow example requires. It also never told the model the `meal_entry_id` that `update_meal` demands.

```ruby
# app/jobs/ai_chat_turn_job.rb
class AiChatTurnJob < ApplicationJob
  MAX_ITERATIONS = 5

  def perform(conversation:, user_message:)
    user = conversation.user
    client, model = Ai::ClientFactory.for(user)   # BYO key or shared key, see §7

    conversation.messages.create!(role: "user", content: [{ type: "text", text: user_message }])

    MAX_ITERATIONS.times do
      response = client.messages.create(
        model: model,
        max_tokens: 4096,                          # NOT 1024 — see §5
        system_: Ai::Prompts.meal_logging(user),   # note trailing underscore in the Ruby SDK
        messages: conversation.to_api_messages,    # windowed — see §7
        tools: Ai::MealTools::ALL
      )

      conversation.messages.create!(role: "assistant", content: response.content)
      Ai::Broadcaster.stream_text(conversation, response)

      break unless response.stop_reason == :tool_use

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

The Ruby SDK's `client.beta.messages.tool_runner` will drive this loop for you if you'd rather not own it; the manual form is shown because we need control over persistence and Turbo broadcasting between turns.

### Dispatcher — corrected

> **Rev. 1's version raised on the first meal.** `create!(tool_use.input.merge(...))` mass-assigns the model's tool input, which includes `food_name`, `confidence`, and `assumptions` — none of which were columns. `ActiveRecord::UnknownAttributeError`. Those columns now exist (§4), and attributes are whitelisted regardless: tool input is model output and should never be trusted into `create!`.

```ruby
# app/services/ai/tool_handlers.rb
module Ai
  module ToolHandlers
    MEAL_ATTRS = %w[quantity_grams calories protein_g fat_g carbs_g
                    meal_type confidence assumptions].freeze

    def self.dispatch(user:, conversation:, tool_use:)
      payload =
        case tool_use.name
        when "log_meal"     then log_meal(user, conversation, tool_use.input)
        when "update_meal"  then update_meal(user, tool_use.input)
        when "log_exercise" then log_exercise(user, tool_use.input)
        else { error: "unknown tool #{tool_use.name}" }
        end

      { type: "tool_result", tool_use_id: tool_use.id, content: payload.to_json }
    rescue => e
      Rails.logger.error("tool #{tool_use.name} failed: #{e.class}: #{e.message}")
      { type: "tool_result", tool_use_id: tool_use.id, content: e.message, is_error: true }
    end

    def self.log_meal(user, conversation, input)
      entry = user.meal_entries.create!(
        input.slice(*MEAL_ATTRS).merge(
          food: Food.match_or_create(input["food_name"], user: user),   # §6 path 2
          raw_input: conversation.last_user_text,
          source: "text",
          consumed_at: Time.current
        )
      )
      conversation.update!(last_meal_entry: entry)
      user.increment!(:ai_parses_this_period)   # per MEAL, not per API call

      # Returning the ID is what makes update_meal possible at all.
      { logged: true, meal_entry_id: entry.id, day_total: user.day_totals(Time.current) }
    end

    def self.update_meal(user, input)
      entry = user.meal_entries.find(input["meal_entry_id"])   # user-scoped: no IDOR
      entry.update!(input.slice(*MEAL_ATTRS))
      { updated: true, meal_entry_id: entry.id, day_total: user.day_totals(Time.current) }
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

Adding a fourth tool (e.g. `undo_last_entry`) is a `when` branch plus a schema.

---

## 14. Open Questions

- **Domain name.** Linode alongside chord-practice.com is the plan; needs a name.
- **USDA FoodData Central API key** — free but requires signup. OpenFoodFacts needs no key and has better barcode coverage outside the US; probably lead with OpenFoodFacts and fall back to USDA.
- **Does `pg_trgm` similarity suffice for repeat-meal matching**, or does it need embeddings? Start with trigram + a user-scoped recency window; only reach for `pgvector` if match rates are poor in real use.
- **What's the minimum viable calibration window?** §9 assumes 2–3 weeks of weight data. Users who log sporadically may never reach it — needs a graceful degradation story.
- **Which outcome from §12's table would still make this worth building?** Worth answering honestly before phase 1, not after phase 9.

### Resolved since rev. 1

- ~~MET table vs. AI for exercise~~ → MET table, plus Health import (§8).
- ~~Kamal vs. Fly.io~~ → Kamal on the existing Linode box.
- ~~Whisper vs. Web Speech API~~ → neither; native on-device STT (§6).
