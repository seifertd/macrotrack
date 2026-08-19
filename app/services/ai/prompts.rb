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

      Set `confidence` honestly. It is shown to the user, and low-confidence entries
      are rendered differently — an overconfident estimate is worse than a hedged one.

      When context includes a prior similar entry, prefer matching it over
      re-deriving from scratch. Consistency between entries matters more than
      per-entry precision.

      Once reasonably confident, call log_meal.
    PROMPT

    def self.meal_logging(user)
      [
        { type: "text", text: stable_block(user), cache_control: { type: "ephemeral" } },
        { type: "text", text: volatile_block(user) }
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

    # Below the cache breakpoint, so it can change every request for free.
    def self.volatile_block(user)
      now = Time.current.in_time_zone(user.timezone)
      totals = user.day_totals(now)

      <<~TEXT.strip
        Current local time: #{now.strftime('%A %-d %B %Y, %-l:%M %p')} (#{user.timezone}).

        Day totals at the start of this turn: #{totals[:calories].to_i} kcal, #{totals[:protein_g].to_i}g protein, #{totals[:fat_g].to_i}g fat, #{totals[:carbs_g].to_i}g carbs.

        Every tool that writes an entry returns `day_total`. That is the complete total
        for the whole day after your change — not the entry you just logged, and not a
        number to add to anything. Once a tool has returned a day_total this turn, it
        replaces the figures above; quote it as-is. Worked example: the line above says
        900 kcal, a tool returns day_total 1400 — the day is at 1400 kcal, not 2300.
      TEXT
    end
  end
end
