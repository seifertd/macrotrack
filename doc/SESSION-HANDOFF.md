# Handoff — 2026-08-22

Disposable working note. Delete it once the open items below are done or moved into
`IMPLEMENTATION-PLAN.md`.

**State:** tree clean, `main` at `a8f9b68`, production deployed at the same commit, CI green.
275+ Ruby tests, 7 JavaScript tests (`bin/rails test:js`), rubocop and brakeman clean.

## Where we got to

WP5-a and WP5-b are both shipped and closed in the plan (12 of 18 done; **next is WP8 —
weight + trends**). Voice records with MediaRecorder, converts to 16 kHz mono wav in the
browser, and transcribes with whisper.cpp on das in ~8s. `small.en`, no prompt, greedy
decoding + flash attention — all four of those chosen by measurement, reasons in
`Stt::Whisper` and in the plan's WP5-b entry.

Then a search thread: food search is now one ranked list (entries and foods interleaved,
best match first, with a chip saying which kind of row it is), and imported recipes carry
`source: "recipe"` rather than claiming to have been entered by hand.

## In flight — start here

**An orphan-food sweep, agreed but not written.** The framing, settled in conversation:

> Delete a food when nothing references it **and** it holds nothing a name alone doesn't —
> no macros, no `serving_g`, no barcode.

Not "was it created by the chat": `source` is `user_custom` for both the chat's rows and
anything typed into the manual form, and provenance is not the property that matters. The
rule as stated protects the 190 imported recipes (which have macros and mostly zero
entries — `#406 Portobello Sandwich` is the example that proves "no entries" cannot be the
rule on its own), and cleans up after the chat *and* the manual form.

A periodic sweep rather than a hook on entry deletion, because `update_meal` re-pointing an
entry at a different food strands the old one too — a deletion hook is incomplete by
construction. `config/recurring.yml` already carries one entry
(`clear_solid_queue_finished_jobs`, hourly at minute 12) and is the place for it.

Sizing, so nobody over-invests: these rows are **invisible**. Every read filters on having
macros — `Food.loggable` in search, `where.not(calories_per_100g: nil)` in the chat's hints
— so this is housekeeping, not a user-facing bug. `#468 Roast beef with roast root
vegetables (no gravy)` is one such row sitting in production now.

**The question that was being answered when the session ended:** what the Solid Queue
recurring job does. Answer: `config/recurring.yml` runs
`SolidQueue::Job.clear_finished_in_batches(sleep_between_batches: 0.3)` every hour at
minute 12, which reaps finished job rows so the queue tables don't grow forever. It is
Solid Queue's own housekeeping and has nothing to do with this app's data.

## Deliberately deferred

- **A database view for search.** Would give one query, true global ranking and real
  pagination, and would let the GIN trigram index earn its keep. Worth doing at a few
  thousand foods; buys nothing measurable at 224 and 0.2ms. User agreed to defer.
- **`food_id` on the `log_meal` tool.** Would stop the same dish splitting into two rows
  and let entries attach to rows carrying crafted per-100g figures. Held until there is
  evidence of an actual duplicate of the *same* dish — the five foods the chat created on
  22 August were four legitimate variants and one orphan.
- **§6's IndexedDB retry queue** for a failed upload. Real offline work, not four lines.
- **A faster box for transcription.** whisper.cpp threads nearly linearly, so 4 cores would
  roughly halve the ~8s. Paying ~$20/month more to avoid a $0.32/month API is a bad trade
  on cost alone; do it for the headroom das's other four apps want, not to buy back
  seconds.

## Things that will bite someone who does not know them

- **`Food.match_or_create` does not match.** It is an exact lowercase lookup, and the
  comment promising trigram matching dates to WP1. Renaming it honestly is a loose end.
- **A `?` in user text must never reach `where(sql, arg)`** once the text has been quoted
  into the SQL string — it counts as a bind placeholder and raises before the query is
  sent. Fixed twice on 22 August (`Meals::Matcher`, then the search ranking); the pattern
  to copy is `Food.word_score_sql`.
- **Whisper narrates itself on stderr.** Use `capture3` and read stdout, or
  "read_audio_data: trying to decode with miniaudio" becomes part of somebody's dinner.
- **Do not prompt whisper with the foods table.** Measured on 22 August: it did not fix the
  food noun it was meant to fix and it deleted a quantity. The note is in `Stt::Whisper`.
- **The offsite backup puller is installed at `~/Tools/pull_macros_backup.sh` on `xbmc`**,
  separate from the repo copy at `script/pull_backups_xbmc.sh`. Editing one does not update
  the other.
