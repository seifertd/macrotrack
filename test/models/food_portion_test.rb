require "test_helper"

class FoodPortionTest < ActiveSupport::TestCase
  setup do
    @doug = users(:doug)
    @yogurt = Food.create!(name: "Oui Black Cherry Yogurt", barcode: "0070470496740",
      source: "openfoodfacts", calories_per_100g: 123, protein_per_100g: 3.5,
      carbs_per_100g: 16.9, fat_per_100g: 4.9)
  end

  test "100g is the reference, so it comes back as the per-100g figures" do
    scaled = FoodPortion.new(@yogurt, grams: 100).scaled

    assert_equal 123, scaled[:calories].to_f
    assert_equal 3.5, scaled[:protein_g].to_f
    assert_equal 16.9, scaled[:carbs_g].to_f
    assert_equal 4.9, scaled[:fat_g].to_f
  end

  test "scales every figure by the same factor" do
    scaled = FoodPortion.new(@yogurt, grams: 150).scaled

    assert_in_delta 184.5, scaled[:calories].to_f, 0.01
    assert_in_delta 5.25, scaled[:protein_g].to_f, 0.01
    assert_in_delta 25.35, scaled[:carbs_g].to_f, 0.01
    assert_in_delta 7.35, scaled[:fat_g].to_f, 0.01
  end

  test "defaults to the reference weight when no grams are given" do
    assert_equal 100, FoodPortion.new(@yogurt).grams.to_f
    assert_equal 1, FoodPortion.new(@yogurt).factor.to_f
  end

  test "ignores a blank or unparseable weight rather than logging zero" do
    assert_equal 100, FoodPortion.new(@yogurt, grams: "").grams.to_f
    assert_equal 100, FoodPortion.new(@yogurt, grams: "a lot").grams.to_f
  end

  test "a macro the label did not carry stays unknown, not zero" do
    sparse = Food.create!(name: "Mystery Bar", source: "openfoodfacts", calories_per_100g: 400)

    scaled = FoodPortion.new(sparse, grams: 50).scaled

    assert_equal 200, scaled[:calories].to_f
    assert_nil scaled[:protein_g]
  end

  test "is not loggable without calories" do
    nameless = Food.create!(name: "No Numbers", source: "user_custom")

    assert_not FoodPortion.new(nameless, grams: 100).loggable?
    assert FoodPortion.new(@yogurt, grams: 100).loggable?
  end

  test "is not loggable at zero grams" do
    assert_not FoodPortion.new(@yogurt, grams: 0).loggable?
  end

  test "logs onto the given user's day as a barcode entry" do
    entry = FoodPortion.new(@yogurt, grams: 150).log_for!(@doug)

    assert_equal @doug, entry.user
    assert_equal @yogurt, entry.food
    assert_equal "barcode", entry.source
    assert_equal 150, entry.quantity_grams.to_f
    assert_in_delta 184.5, entry.calories.to_f, 0.01
  end

  test "a barcode entry is not hedged the way an estimate is" do
    entry = FoodPortion.new(@yogurt, grams: 100).log_for!(@doug)

    assert_not entry.estimated?, "the label was read, not guessed at"
    assert_nil entry.confidence
  end
end
