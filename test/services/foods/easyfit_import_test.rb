require "test_helper"

class Foods::EasyfitImportTest < ActiveSupport::TestCase
  test "derives per-100g values from the serving weight" do
    result = Foods::EasyfitImport.import("Magic Juice").sole
    food = result.food

    # 8g protein, 20g carbs, 8g fat in a 226.8g cup = 184 kcal, or 81.13 per 100g.
    assert_equal 81.13, food.calories_per_100g.to_f
    assert_equal 3.53, food.protein_per_100g.to_f
    assert_equal 8.82, food.carbs_per_100g.to_f
    assert_equal 3.53, food.fat_per_100g.to_f
    assert_equal "user_custom", food.source
  end

  test "calories come from the macros, not the export's stated figure" do
    result = Foods::EasyfitImport.import("Magic Juice").sole

    assert_equal 184.0, result.macro_calories
    assert_equal 163.0, result.stated_calories
    assert_equal 12.9, result.calorie_gap_percent, "a gap this size should be reported, not silently averaged"
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
    assert_equal 81.13, existing.reload.calories_per_100g.to_f
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
