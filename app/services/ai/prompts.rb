module Ai
  # Design §9. Returns the `system` array rather than a string, because the cache
  # breakpoint has to sit on a block boundary.
  #
  # The split is the whole point: block one is byte-stable for a given user, so it
  # (and the tool schemas, which render ahead of it) can be cached. Block two carries
  # the clock and the running totals and sits *after* the breakpoint. Put a timestamp
  # in block one and caching silently stops working, with nothing in the response to
  # tell you — the only symptom is cache_read_input_tokens quietly staying at zero.
  module Prompts
    INSTRUCTIONS = <<~PROMPT.freeze
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

      The user is the authority on what they ate, and a meal that resembles one already
      on today's list is not a question. People eat the same thing twice, and they delete
      an entry and add it again. Never ask whether a repeat is deliberate and never hold
      a meal back because the same food is already logged — log it, and if a duplicate
      looks likely say so in a clause while logging. "Another repeat, or genuinely a
      third pair of figs?" is the wrong answer to "two small figs": it costs the user a
      second turn to ask for what they already asked for.

      Set `confidence` honestly. It is shown to the user, and low-confidence entries
      are rendered differently — an overconfident estimate is worse than a hedged one.

      When context includes a prior similar entry, prefer matching it over
      re-deriving from scratch. Consistency between entries matters more than
      per-entry precision.

      Once reasonably confident, call log_meal.
    PROMPT

    def self.meal_logging(user, hints: [])
      [
        { type: "text", text: stable_block(user), cache_control: { type: "ephemeral" } },
        { type: "text", text: [ volatile_block(user), hints_block(hints) ].compact.join("\n\n") }
      ]
    end

    # Everything here changes only when the household does.
    def self.stable_block(user)
      members = user.household_members.map(&:name)

      <<~TEXT.strip
        #{INSTRUCTIONS}
        You are logging for #{user.name}, whose daily calorie target is #{user.daily_calorie_target} kcal.

        #{household_line(user, members)}
      TEXT
    end

    def self.household_line(user, members)
      if members.empty?
        "#{user.name} is the only member of this household, so never call copy_to_household_member."
      else
        "Other members of this household, for copy_to_household_member: #{members.join(', ')}."
      end
    end

    # Design §7 path 1, the half that reaches the model: what this household already has
    # on file that resembles what was just said. Without it the model is asked to name a
    # food from scratch every time, and §9 tells it to read an odd-looking name as a
    # garbled transcript — which is how "magic juice" got logged as mango juice while a
    # Magic Juice row sat in the database with its macros filled in.
    def self.hints_block(hints)
      return nil if hints.blank?

      lines = hints.map { |hint| "- #{describe(hint)}" }

      <<~TEXT.strip
        This household already has these on file, most similar first:

        #{lines.join("\n")}

        If one of them is plainly what the user means, use that name **exactly** as
        written above and base the numbers on it rather than estimating afresh — these
        are records of what was actually eaten, which beats any estimate you could make.
        A name that looks misspelled or odd is likely one of these, not a transcription
        error. If none of them fit, ignore this list and carry on as usual.
      TEXT
    end

    def self.describe(hint)
      return "#{hint.name} — #{number(hint.food.calories_per_100g)} kcal per 100g, " \
             "#{number(hint.food.protein_per_100g)}g protein, #{number(hint.food.fat_per_100g)}g fat, " \
             "#{number(hint.food.carbs_per_100g)}g carbs" unless hint.entry?

      entry = hint.entry
      portion = entry.quantity_grams.present? ? " for #{number(entry.quantity_grams)}g" : ""

      "#{hint.name} — logged #{number(entry.calories)} kcal#{portion} " \
        "(#{number(entry.protein_g)}g protein, #{number(entry.fat_g)}g fat, #{number(entry.carbs_g)}g carbs) " \
        "on #{entry.user.local_date(entry.consumed_at).strftime('%-d %B')}"
    end

    # The day as the database has it, which is not the same thing as the day the
    # conversation above describes. Entries are logged, edited and deleted on screens
    # this thread never sees, and a turn from an hour ago saying a meal was logged is not
    # evidence that it still is. Without this the model refuses to log a meal it can see
    # itself logging earlier in the transcript, however long ago the user deleted it —
    # which is exactly what it did on 22 August with two small figs.
    def self.log_block(user, now)
      entries = user.entries_on(user.local_date(now)).includes(:food).order(:consumed_at)

      return "Nothing is logged for today yet." if entries.empty?

      lines = entries.map do |entry|
        portion = entry.quantity_grams.present? ? ", #{number(entry.quantity_grams)}g" : ""

        "- ##{entry.id} #{entry.consumed_at.in_time_zone(user.timezone).strftime('%-l:%M %p').downcase} " \
          "#{entry.display_name} — #{number(entry.calories)} kcal#{portion}"
      end

      <<~TEXT.strip
        Logged today, as of this turn:

        #{lines.join("\n")}

        That list is the whole of today's log right now, and it is authoritative. If a
        meal the conversation above says was logged is not on it, it has been deleted or
        edited since — believe the list, not the transcript. It is here so you know what
        the day holds and can correct any of it: the numbers after the # are
        meal_entry_id values, so a correction goes straight to update_meal without asking
        the user which entry they mean. It is never a reason to hesitate over logging
        something again.
      TEXT
    end

    def self.number(value)
      value.to_f.round
    end

    # Below the cache breakpoint, so it can change every request for free.
    def self.volatile_block(user)
      now = Time.current.in_time_zone(user.timezone)
      totals = user.day_totals(now)

      <<~TEXT.strip
        Current local time: #{now.strftime('%A %-d %B %Y, %-l:%M %p')} (#{user.timezone}).

        Day totals at the start of this turn: #{totals[:calories].to_i} kcal, #{totals[:protein_g].to_i}g protein, #{totals[:fat_g].to_i}g fat, #{totals[:carbs_g].to_i}g carbs.

        #{log_block(user, now)}

        Every tool that writes an entry returns `day_total`. That is the complete total
        for the whole day after your change — not the entry you just logged, and not a
        number to add to anything. Once a tool has returned a day_total this turn, it
        replaces the figures above; quote it as-is. Worked example: the line above says
        900 kcal, a tool returns day_total 1400 — the day is at 1400 kcal, not 2300.
      TEXT
    end
  end
end
