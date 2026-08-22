module Ai
  # Design §16. Plain Ruby that takes a hash and touches the database, which is why
  # the tests for this package live here and need no API in the loop.
  module ToolHandlers
    MEAL_ATTRS = %w[ quantity_grams calories protein_g fat_g carbs_g
                     meal_type confidence assumptions ].freeze

    def self.dispatch(user:, conversation:, tool_use:)
      # The SDK parses responses with symbolized keys; the handlers below read strings
      # so the same code works against a fixture hash. One conversion, one place.
      input = tool_use.input.to_h.deep_stringify_keys

      payload =
        case tool_use.name
        when "log_meal"                 then log_meal(user, conversation, input)
        when "update_meal"              then update_meal(user, input)
        when "copy_to_household_member" then copy_to_member(user, input)
        when "log_exercise"             then log_exercise(user, input)
        else { error: "unknown tool #{tool_use.name}" }
        end

      { type: "tool_result", tool_use_id: tool_use.id, content: payload.to_json }
    rescue => e
      # A failed tool is a fact the model should read and respond to, not an exception
      # that kills the turn. `is_error` is what lets it ask instead of guessing.
      Rails.logger.error("tool #{tool_use.name} failed: #{e.class}: #{e.message}")
      { type: "tool_result", tool_use_id: tool_use.id, content: e.message, is_error: true }
    end

    def self.log_meal(user, conversation, input)
      entry = user.meal_entries.create!(
        # Whitelisted: tool input is model output and must never be mass-assigned.
        input.slice(*MEAL_ATTRS).merge(
          food: Food.match_or_create(input["food_name"]),
          raw_input: conversation.last_user_text,
          source: conversation.last_input_source,
          consumed_at: Time.current
        )
      )
      # Returning the ID is what makes update_meal and copy_to_household_member possible.
      { logged: true, meal_entry_id: entry.id, day_total: day_total(user) }
    end

    def self.update_meal(user, input)
      entry = user.meal_entries.find(input["meal_entry_id"])   # user-scoped
      attributes = input.slice(*MEAL_ATTRS)

      # UPDATE_MEAL's schema accepts food_name, so honour it. Correcting "chicken bowl"
      # to "double chicken bowl" is the same gesture as correcting the calories, and
      # dropping it silently would leave the entry labelled with the old dish.
      attributes[:food] = Food.match_or_create(input["food_name"]) if input["food_name"].present?

      entry.update!(attributes)
      { updated: true, meal_entry_id: entry.id, day_total: day_total(user) }
    end

    def self.copy_to_member(user, input)
      entry  = user.meal_entries.find(input["meal_entry_id"])
      target = resolve_member(user, input["member_name"])
      copy   = target.meal_entries.create!(
        entry.slice(*MEAL_ATTRS, "food_id", "raw_input").merge(
          source: "copied", consumed_at: Time.current
        )
      )
      # WP6 makes this copy portioned — the two of us eat the same dinner in different
      # amounts. Until the tool carries a portion, a verbatim copy is what §16 specifies.
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

    # day_totals hands back BigDecimals, which serialize as JSON strings. The model
    # reads these back to talk about the day, so round them to what a person would say.
    def self.day_total(user)
      user.day_totals(Time.current).transform_values { |value| value.to_f.round }
    end
  end
end
