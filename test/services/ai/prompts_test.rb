require "test_helper"

class Ai::PromptsTest < ActiveSupport::TestCase
  setup { @user = users(:doug) }

  test "the cached block is byte-stable across requests" do
    first = Ai::Prompts.meal_logging(@user).first[:text]
    later = travel_to(3.hours.from_now) { Ai::Prompts.meal_logging(@user).first[:text] }

    assert_equal first, later, "an interpolated clock above the breakpoint kills caching silently"
  end

  test "the volatile block carries the clock and the running totals" do
    # 2026-08-16 local is the day the fixtures' late-night snack lands on.
    travel_to Time.utc(2026, 8, 17, 6, 45) do
      volatile = Ai::Prompts.meal_logging(@user).last[:text]

      assert_match(/Current local time/, volatile)
      assert_match(/not 2300/, volatile)
      assert_match(/300 kcal/, volatile)
      assert_nil Ai::Prompts.meal_logging(@user).last[:cache_control]
    end
  end

  test "the cached block names the household so copy_to_household_member has targets" do
    assert_match(/Partner/, Ai::Prompts.meal_logging(@user).first[:text])
  end

  test "a household of one is told not to call the copy tool" do
    solo = users(:neighbor)

    assert_match(/never call copy_to_household_member/, Ai::Prompts.meal_logging(solo).first[:text])
  end

  test "the volatile block follows the user's own timezone" do
    travel_to Time.utc(2026, 8, 18, 6, 30) do
      assert_match(/11:30 PM/, Ai::Prompts.meal_logging(@user).last[:text])
      assert_match(/2:30 AM/, Ai::Prompts.meal_logging(users(:neighbor)).last[:text])
    end
  end
end
