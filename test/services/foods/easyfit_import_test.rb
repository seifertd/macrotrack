require "test_helper"

class Foods::EasyfitImportTest < ActiveSupport::TestCase
  test "derives per-100g values from the serving weight" do
    result = Foods::EasyfitImport.import("Magic Juice").sole
    food = result.food

    # 163 kcal in a 226.8g glass is 71.87 per 100g, and the macros are rescaled to agree.
    assert_equal 71.87, food.calories_per_100g.to_f
    assert_equal 3.12, food.protein_per_100g.to_f
    assert_equal 7.81, food.carbs_per_100g.to_f
    assert_equal 3.12, food.fat_per_100g.to_f
    assert_equal "user_custom", food.source
  end

  test "calories come from the stated figure, not the macros" do
    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert_equal 163.0, result.stated_calories
    assert_equal 184.0, result.macro_calories
    assert_equal 12.9, result.calorie_gap_percent

    assert_equal 71.87, result.food.calories_per_100g.to_f,
      "the serving Doug crafted is the anchor; 81.13 was the old macro-derived figure"
  end

  test "a row whose macros disagree with its calories is flagged, not rejected" do
    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert result.macros_suspect?, "12.9% is past the tolerance"
    assert_equal 71.87, result.food.calories_per_100g.to_f,
      "the calorie figure is still trustworthy — only the split is in doubt"
  end

  test "macros are rescaled to add up to the stated calories" do
    food = Foods::EasyfitImport.import("Magic Juice").sole.food

    reconstructed = food.protein_per_100g.to_f * 4 + food.carbs_per_100g.to_f * 4 + food.fat_per_100g.to_f * 9

    assert_in_delta food.calories_per_100g.to_f, reconstructed, 0.1,
      "the export's 8/20/8 split is kept in proportion but scaled down to 163 kcal"
  end

  test "a row whose macros already agree is imported untouched and unflagged" do
    result = Foods::EasyfitImport.import("Brie").sole

    assert_not result.macros_suspect?
    assert_equal 0.0, result.calorie_gap_percent
    assert_equal 246.48, result.food.calories_per_100g.to_f
    assert_equal 14.08, result.food.protein_per_100g.to_f
    assert_equal 21.13, result.food.fat_per_100g.to_f
  end

  test "re-running updates the existing row rather than duplicating it" do
    first = Foods::EasyfitImport.import("Magic Juice").sole
    assert first.created

    assert_no_difference -> { Food.count } do
      second = Foods::EasyfitImport.import("Magic Juice").sole
      assert_not second.created
      assert_equal first.food, second.food
    end
  end

  test "an existing food row keeps its identity and gains nutrition" do
    existing = Food.find_or_create_by_name("magic juice")
    assert_nil existing.calories_per_100g

    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert_equal existing, result.food, "matching is case-insensitive, so entries already logged stay attached"
    assert_equal 71.87, existing.reload.calories_per_100g.to_f
  end

  test "refuses a row whose density is physically impossible" do
    # 3.5g of swiss cheese for 90 kcal is 2571 kcal/100g. The weight is a placeholder,
    # and importing it would put a confidently wrong density in front of every future
    # estimate with nothing on the row to flag it.
    error = assert_raises Foods::EasyfitImport::ImplausibleRow do
      Foods::EasyfitImport.import("Swiss Cheese Slice")
    end

    assert_match(/placeholder/, error.message)
    assert_nil Food.find_by("lower(name) = ?", "swiss cheese slice")
  end

  test "refuses a row whose density is implausibly low" do
    assert_raises Foods::EasyfitImport::ImplausibleRow do
      Foods::EasyfitImport.import("Riced Cauliflower & Broccoli")
    end
  end

  test "names a row it cannot find rather than importing nothing quietly" do
    error = assert_raises Foods::EasyfitImport::UnknownFood do
      Foods::EasyfitImport.import("Magic Juice", "Nonexistent Smoothie")
    end

    assert_match(/Nonexistent Smoothie/, error.message)
  end

  test "the export is readable and every row has a name" do
    names = Foods::EasyfitImport.names

    assert_equal 123, names.length
    assert_empty names.select(&:blank?)
    assert_equal names.length, names.uniq.length
  end
end
