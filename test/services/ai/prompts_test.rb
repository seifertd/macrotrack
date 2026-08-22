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

  # Retrieval reaches the model through the volatile block, below the cache breakpoint,
  # so a different set of hints on every message costs nothing in cache hits.
  test "hints are listed below the cache breakpoint, never above it" do
    food = Food.find_or_create_by_name("Magic Juice")
    food.update!(calories_per_100g: 81.13, protein_per_100g: 3.53, fat_per_100g: 3.53, carbs_per_100g: 8.82)
    hints = Meals::Matcher.new(@user, "a glass of magic juice").hints

    blocks = Ai::Prompts.meal_logging(@user, hints: hints)

    assert_match(/Magic Juice — 81 kcal per 100g/, blocks.last[:text])
    assert_no_match(/Magic Juice/, blocks.first[:text])
    assert_equal Ai::Prompts.meal_logging(@user).first[:text], blocks.first[:text],
      "hints must not disturb the cached prefix"
  end

  test "an entry hint carries the portion actually eaten" do
    entry = users(:partner).meal_entries.create!(
      source: "text", consumed_at: 2.hours.ago, quantity_grams: 360, calories: 559,
      protein_g: 30, fat_g: 20, carbs_g: 50, food: Food.find_or_create_by_name("Burst Cherry Tomato Pasta")
    )
    hints = Meals::Matcher.new(@user, "burst cherry tomato pasta").hints

    assert_equal entry, hints.first.entry
    assert_match(/Burst Cherry Tomato Pasta — logged 559 kcal for 360g/, Ai::Prompts.hints_block(hints))
  end

  test "no hints means no list, rather than an empty heading" do
    assert_nil Ai::Prompts.hints_block([])
    assert_no_match(/already has these on file/, Ai::Prompts.meal_logging(@user).last[:text])
  end

  test "the volatile block follows the user's own timezone" do
    travel_to Time.utc(2026, 8, 18, 6, 30) do
      assert_match(/11:30 PM/, Ai::Prompts.meal_logging(@user).last[:text])
      assert_match(/2:30 AM/, Ai::Prompts.meal_logging(users(:neighbor)).last[:text])
    end
  end
  # Production, 22 August: an entry was logged by voice, deleted from the day screen, and
  # the model then refused to log it again because the transcript above still showed
  # itself logging it. The transcript is a record of what was said, not of what is on the
  # log now, and only one of those two is a fact.
  test "the day's log is stated as it stands, not as the conversation remembers it" do
    travel_to Time.utc(2026, 8, 17, 6, 45) do
      entry = @user.meal_entries.create!(
        source: "voice", calories: 40, quantity_grams: 60, consumed_at: 1.hour.ago,
        food: Food.find_or_create_by_name("Fresh figs (2 small)")
      )

      assert_match(/##{entry.id} .* Fresh figs \(2 small\) — 40 kcal, 60g/,
        Ai::Prompts.meal_logging(@user).last[:text])

      entry.destroy!

      volatile = Ai::Prompts.meal_logging(@user).last[:text]

      assert_no_match(/Fresh figs/, volatile)
      assert_match(/authoritative/, volatile)
      assert_match(/never refuse to log something on the grounds that you remember/, volatile.squish)
    end
  end

  test "an empty day says so rather than heading an empty list" do
    travel_to Time.utc(2026, 8, 17, 6, 45) do
      @user.meal_entries.destroy_all

      assert_match(/Nothing is logged for today yet/, Ai::Prompts.meal_logging(@user).last[:text])
    end
  end

  test "the day's log sits below the cache breakpoint with the rest of the volatile half" do
    travel_to Time.utc(2026, 8, 17, 6, 45) do
      assert_no_match(/Logged today/, Ai::Prompts.meal_logging(@user).first[:text])
    end
  end
end
