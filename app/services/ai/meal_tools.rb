module Ai
  # Design §15. Pure data — the schemas the model is handed. Deliberately no behavior:
  # the tool list is part of the cached prompt prefix, so anything that varies per
  # request must not live here.
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

    # The household affordance from §7. Takes an explicit target, because "the other
    # member" stops being well-defined the moment there are three of them. The system
    # prompt lists the household's member names, so the model has them to hand.
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

    ALL = [ LOG_MEAL, UPDATE_MEAL, COPY_TO_HOUSEHOLD_MEMBER, LOG_EXERCISE ].freeze
  end
end
