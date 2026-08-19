require "test_helper"

class FoodPortionTest < ActiveSupport::TestCase
  setup do
    @doug = users(:doug)
    @yogurt = Food.create!(name: "Oui Black Cherry Yogurt", barcode: "0070470496740",
      source: "openfoodfacts", calories_per_100g: 123, protein_per_100g: 3.5,
      carbs_per_100g: 16.9, fat_per_100g: 4.9)
  end

  def serving_food
    @serving_food ||= Food.create!(name: "Knudsen cottage cheese", barcode: "049900342643",
      source: "openfoodfacts", calories_per_100g: 93.22, protein_per_100g: 9.32,
      carbs_per_100g: 5.08, fat_per_100g: 4.24, serving_g: 115, serving_label: "0.5 cup (115 g)")
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

  test "a food that knows its serving offers servings, not gram presets" do
    portion = FoodPortion.new(serving_food)

    assert portion.by_serving?
    assert_equal 115, portion.reference_grams.to_f, "one serving is the default portion"
    assert_equal [ "\u00bd serving", "1 serving", "1\u00bd servings", "2 servings" ],
      portion.chips.map { |c| c[:label] }
    assert_equal [ 0.5, 1.0, 1.5, 2.0 ], portion.chips.map { |c| c[:multiplier] }
  end

  test "a food without a serving falls back to gram presets" do
    portion = FoodPortion.new(@yogurt)

    assert_not portion.by_serving?
    assert_equal 100, portion.reference_grams.to_f
    assert_equal [ "30g", "50g", "100g", "150g", "200g" ], portion.chips.map { |c| c[:label] }
  end

  test "servings resolve against the serving weight" do
    assert_equal 115, FoodPortion.new(serving_food, servings: 1).grams.to_f
    assert_equal 57.5, FoodPortion.new(serving_food, servings: 0.5).grams.to_f
    assert_equal 172.5, FoodPortion.new(serving_food, servings: 1.5).grams.to_f
  end

  test "half a serving is half the calories" do
    full = FoodPortion.new(serving_food, servings: 1).scaled[:calories].to_f
    half = FoodPortion.new(serving_food, servings: 0.5).scaled[:calories].to_f

    assert_in_delta 107.2, full, 0.01, "93.22 kcal/100g over a 115g serving"
    assert_in_delta full / 2, half, 0.01
  end

  test "grams win over servings, because they are the more specific answer" do
    portion = FoodPortion.new(serving_food, grams: 200, servings: 1)

    assert_equal 200, portion.grams.to_f
  end

  test "servings are ignored when the food has no serving weight to resolve them" do
    portion = FoodPortion.new(@yogurt, servings: 2)

    assert_equal 100, portion.grams.to_f, "better the reference than logging 2g"
    assert_nil portion.servings
  end

  test "says what was eaten in the unit it was chosen in" do
    assert_equal "1 serving", FoodPortion.new(serving_food, servings: 1).label
    assert_equal "\u00bd serving", FoodPortion.new(serving_food, servings: 0.5).label
    assert_equal "150g", FoodPortion.new(@yogurt, grams: 150).label
  end

  test "the entry still lands in grams, whatever unit it was said in" do
    entry = FoodPortion.new(serving_food, servings: 0.5).log_for!(@doug)

    assert_equal 57.5, entry.quantity_grams.to_f
    assert_in_delta 53.6, entry.calories.to_f, 0.01
  end

  test "a barcode entry is not hedged the way an estimate is" do
    entry = FoodPortion.new(@yogurt, grams: 100).log_for!(@doug)

    assert_not entry.estimated?, "the label was read, not guessed at"
    assert_nil entry.confidence
  end
end
