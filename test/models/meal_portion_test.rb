require "test_helper"

class MealPortionTest < ActiveSupport::TestCase
  setup do
    @doug = users(:doug)
    @partner = users(:partner)
    @source = @doug.meal_entries.create!(
      source: "text", consumed_at: 2.hours.ago, quantity_grams: 360, calories: 559,
      protein_g: 30, fat_g: 20, carbs_g: 50, meal_type: "dinner", confidence: "medium",
      assumptions: "Assumed a pub-sized bowl.", food: Food.find_or_create_by_name("chilli")
    )
  end

  test "half the grams is half the meal" do
    portion = MealPortion.new(@source, grams: 180)

    assert_equal 0.5, portion.factor.to_f
    assert_equal 279.5, portion.scaled[:calories].to_f
    assert_equal 15.0, portion.scaled[:protein_g].to_f
    assert_equal 10.0, portion.scaled[:fat_g].to_f
    assert_equal 25.0, portion.scaled[:carbs_g].to_f
    assert_equal 180.0, portion.scaled[:quantity_grams].to_f
  end

  test "the plan's worked example reads as 280 kcal on screen" do
    entry = MealPortion.new(@source, grams: 180).log_for!(@partner)

    # Stored at full precision and rounded only for display, which is what stops the
    # macros drifting away from the calories: nothing is rounded before it is summed.
    assert_equal 279.5, entry.calories.to_f
    assert_equal "280", ApplicationController.helpers.calories(entry.calories)
  end

  test "scaling preserves the macro-to-calorie relationship exactly" do
    original_ratio = macro_calories(@source) / @source.calories.to_f

    [ 0.25, 0.5, 1.5, 3 ].each do |factor|
      scaled = MealPortion.new(@source, grams: 360 * factor).scaled
      ratio = (scaled[:protein_g] * 4 + scaled[:carbs_g] * 4 + scaled[:fat_g] * 9) / scaled[:calories]

      assert_in_delta original_ratio, ratio.to_f, 0.0001, "rounding drifted the macros at #{factor}×"
    end
  end

  test "a multiplier scales an entry that was never weighed" do
    unweighed = @doug.meal_entries.create!(
      source: "manual", consumed_at: 1.hour.ago, calories: 500, protein_g: 10, fat_g: 10, carbs_g: 10
    )
    portion = MealPortion.new(unweighed, multiplier: 0.5)

    assert_not portion.by_grams?
    assert_equal 250.0, portion.scaled[:calories].to_f
    assert_nil portion.scaled[:quantity_grams]
    assert_equal "0.5×", portion.label
  end

  test "grams win over a multiplier when the source was weighed" do
    portion = MealPortion.new(@source, grams: 90, multiplier: 2)

    assert_equal 0.25, portion.factor.to_f
    assert_equal "90g", portion.label
  end

  test "no portion given means the same as they had" do
    portion = MealPortion.new(@source)

    assert_equal 1, portion.factor
    assert_equal 559.0, portion.scaled[:calories].to_f
  end

  test "the copy carries source, timestamp, and the food it points at" do
    freeze_time do
      entry = MealPortion.new(@source, grams: 180).log_for!(@partner)

      assert_equal @partner, entry.user
      assert_equal "copied", entry.source
      assert_equal Time.current, entry.consumed_at
      assert_equal @source.food_id, entry.food_id
      assert_equal "dinner", entry.meal_type
      assert_equal "medium", entry.confidence
    end
  end

  test "a resized copy says so, because the original's assumptions no longer describe it" do
    portion = MealPortion.new(@source, grams: 180)

    assert_match(/Portioned to 180g of Doug's entry/, portion.assumptions)
    assert_match(/pub-sized bowl/, portion.assumptions, "composition notes are still worth keeping")
  end

  test "an unresized copy leaves the assumptions alone" do
    assert_equal "Assumed a pub-sized bowl.", MealPortion.new(@source, grams: 360).assumptions
  end

  test "junk in the portion field falls back to the whole thing rather than blowing up" do
    [ "", "  ", "abc", "0" ].each do |value|
      assert_equal 559.0, MealPortion.new(@source, grams: value).scaled[:calories].to_f, "grams=#{value.inspect}"
    end
  end

  private
    def macro_calories(entry)
      entry.protein_g.to_f * 4 + entry.carbs_g.to_f * 4 + entry.fat_g.to_f * 9
    end
end
