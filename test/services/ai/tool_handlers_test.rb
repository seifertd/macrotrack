require "test_helper"

class Ai::ToolHandlersTest < ActiveSupport::TestCase
  setup do
    @user = users(:doug)
    @partner = users(:partner)
    @conversation = @user.conversation!
    @conversation.messages.create!(
      role: "user", input_source: "text",
      content: [ { "type" => "text", "text" => "a bowl of chili" } ]
    )
  end

  test "log_meal creates an entry and returns its id" do
    result = dispatch("log_meal", {
      "food_name" => "bowl of chili", "quantity_grams" => 400, "calories" => 520,
      "protein_g" => 32, "fat_g" => 24, "carbs_g" => 38,
      "meal_type" => "dinner", "confidence" => "medium", "assumptions" => "Assumed a pub-sized bowl."
    })

    payload = JSON.parse(result[:content])
    entry = MealEntry.find(payload["meal_entry_id"])

    assert payload["logged"]
    assert_equal @user, entry.user
    assert_equal 520, entry.calories
    assert_equal "bowl of chili", entry.food.name
    assert_equal "Assumed a pub-sized bowl.", entry.assumptions
  end

  test "log_meal stamps the entry with the transcript and how it arrived" do
    result = dispatch("log_meal", meal_input)
    entry = MealEntry.find(JSON.parse(result[:content])["meal_entry_id"])

    assert_equal "a bowl of chili", entry.raw_input
    assert_equal "text", entry.source
  end

  test "log_meal ignores attributes outside the whitelist" do
    result = dispatch("log_meal", meal_input.merge("user_id" => @partner.id, "source" => "barcode"))
    entry = MealEntry.find(JSON.parse(result[:content])["meal_entry_id"])

    assert_equal @user, entry.user, "tool input must never be mass-assigned"
    assert_equal "text", entry.source
  end

  test "log_meal returns the running day total" do
    result = dispatch("log_meal", meal_input.merge("calories" => 100))
    payload = JSON.parse(result[:content])

    # The fixtures already put 800 kcal on Doug's day, across two entries.
    assert_equal @user.day_totals(Time.current)[:calories].to_f.round, payload["day_total"]["calories"]
  end

  test "update_meal changes the entry rather than creating a second one" do
    logged = JSON.parse(dispatch("log_meal", meal_input)[:content])

    assert_no_difference -> { @user.meal_entries.count } do
      result = dispatch("update_meal", {
        "meal_entry_id" => logged["meal_entry_id"],
        "calories" => 780, "protein_g" => 60, "fat_g" => 30, "carbs_g" => 45,
        "food_name" => "bowl of chili, double meat"
      })
      assert JSON.parse(result[:content])["updated"]
    end

    entry = MealEntry.find(logged["meal_entry_id"])
    assert_equal 780, entry.calories
    assert_equal "bowl of chili, double meat", entry.food.name
  end

  test "update_meal cannot touch another user's entry" do
    theirs = @partner.meal_entries.create!(
      source: "manual", consumed_at: Time.current, calories: 300
    )

    result = dispatch("update_meal", {
      "meal_entry_id" => theirs.id,
      "calories" => 1, "protein_g" => 1, "fat_g" => 1, "carbs_g" => 1
    })

    assert result[:is_error], "a cross-user update must come back as an error, not a write"
    assert_equal 300, theirs.reload.calories
  end

  test "copy_to_household_member copies to the only other member without being told who" do
    logged = JSON.parse(dispatch("log_meal", meal_input)[:content])

    result = dispatch("copy_to_household_member", { "meal_entry_id" => logged["meal_entry_id"] })
    payload = JSON.parse(result[:content])
    copy = MealEntry.find(payload["meal_entry_id"])

    assert_equal @partner.name, payload["to"]
    assert_equal @partner, copy.user
    assert_equal "copied", copy.source
    assert_equal 520, copy.calories
  end

  test "copy_to_household_member asks rather than guessing when the household has several members" do
    @user.household.users.create!(
      name: "Third", email_address: "third@example.com", password: "a longer secret"
    )

    logged = JSON.parse(dispatch("log_meal", meal_input)[:content])
    result = dispatch("copy_to_household_member", { "meal_entry_id" => logged["meal_entry_id"] })

    assert result[:is_error]
    assert_match(/Which member/, result[:content])
  end

  test "copy_to_household_member refuses a name from outside the household" do
    logged = JSON.parse(dispatch("log_meal", meal_input)[:content])

    result = dispatch("copy_to_household_member", {
      "meal_entry_id" => logged["meal_entry_id"], "member_name" => users(:neighbor).name
    })

    assert result[:is_error]
    assert_match(/No household member named/, result[:content])
    assert_equal 0, users(:neighbor).meal_entries.count
  end

  test "log_exercise computes the burn server-side" do
    result = dispatch("log_exercise", {
      "activity_name" => "running", "duration_minutes" => 30, "intensity" => "moderate"
    })
    payload = JSON.parse(result[:content])
    entry = ExerciseEntry.find(payload["exercise_entry_id"])

    assert_equal "met_estimate", entry.source
    assert_equal 30, entry.duration_minutes
    assert_operator entry.calories_burned, :>, 0
    assert_equal entry.calories_burned.to_f, payload["calories_burned"].to_f
  end

  test "an unknown tool is reported back rather than raised" do
    result = dispatch("delete_everything", {})

    assert_equal "tool_result", result[:type]
    assert_match(/unknown tool/, result[:content])
  end

  test "an exception becomes an is_error result, not a dead turn" do
    result = dispatch("update_meal", {
      "meal_entry_id" => 0, "calories" => 1, "protein_g" => 1, "fat_g" => 1, "carbs_g" => 1
    })

    assert result[:is_error]
    assert_equal "toolu_1", result[:tool_use_id]
  end

  test "symbol-keyed input works too, because that is what the SDK hands back" do
    result = dispatch("log_meal", {
      food_name: "chili", quantity_grams: 400, calories: 520, protein_g: 32,
      fat_g: 24, carbs_g: 38, meal_type: "dinner", confidence: "medium"
    })

    assert JSON.parse(result[:content])["logged"]
  end

  private
    def meal_input
      {
        "food_name" => "bowl of chili", "quantity_grams" => 400, "calories" => 520,
        "protein_g" => 32, "fat_g" => 24, "carbs_g" => 38,
        "meal_type" => "dinner", "confidence" => "medium"
      }
    end

    def dispatch(name, input)
      Ai::ToolHandlers.dispatch(
        user: @user, conversation: @conversation, tool_use: tool_use_block(name, input)
      )
    end
end
