require "test_helper"

class FoodsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @doug = users(:doug)
    sign_in_as @doug
  end

  # The row this whole package exists for: macros, a serving, and nobody has ever
  # eaten it, so neither the repeat picker nor the scanner can reach it.
  def magic_juice
    @magic_juice ||= Food.create!(name: "Magic Juice", source: "user_custom",
      calories_per_100g: 71.87, protein_per_100g: 0.4, carbs_per_100g: 17.2,
      fat_per_100g: 0.1, serving_g: 226.8, serving_label: "1 glass (8 fl oz)")
  end

  test "requires a signed-in user" do
    sign_out
    get food_path(magic_juice)

    assert_redirected_to new_session_path
  end

  test "a food nobody has eaten still has a portion screen" do
    get food_path(magic_juice)

    assert_response :success
    assert_select "h1", text: "Magic Juice"
    assert_select "form[action=?]", log_food_path(magic_juice)
    assert_select "input[type=submit][value=?]", "Log it"
  end

  # Every EasyFit row arrives with a serving weight — the importer rejects one without —
  # so this is the case that matters for all ~141 of them.
  test "a food that knows its serving defaults to one and offers fractions of it" do
    get food_path(magic_juice)

    assert_select "input[name=grams][value=?]", "227"
    assert_select "[data-multiplier=?]", "0.5"
    assert_select "body", text: /1 serving = 227g/
    assert_select "body", text: /1 glass \(8 fl oz\)/
  end

  test "a food with no serving weight falls back to 100g and gram presets" do
    plain = Food.create!(name: "Lentil Soup", source: "user_custom", calories_per_100g: 62)

    get food_path(plain)

    assert_select "input[name=grams][value=?]", "100"
    assert_select "[data-multiplier=?]", (FoodPortion::GRAM_PRESETS.first / 100.0).to_s
  end

  test "logging by servings lands the right grams on my own day" do
    assert_difference -> { @doug.meal_entries.count }, 1 do
      post log_food_path(magic_juice), params: { servings: 1.5 }
    end

    entry = @doug.meal_entries.order(:id).last
    assert_in_delta 340.2, entry.quantity_grams.to_f, 0.01
    assert_in_delta 244.5, entry.calories.to_f, 0.5
    assert_equal magic_juice.id, entry.food_id
    assert_redirected_to day_path(@doug.local_today)
  end

  # `matched`, not an estimate: the numbers came off a row we already had. It is the
  # difference between the day page hedging the figure and stating it.
  test "the entry says the numbers came from a row we already had" do
    post log_food_path(magic_juice), params: { grams: 100 }

    entry = @doug.meal_entries.order(:id).last
    assert_equal "matched", entry.source
    assert_not entry.estimated?
  end

  test "grams win over servings when both are sent" do
    post log_food_path(magic_juice), params: { grams: 50, servings: 3 }

    assert_equal 50, @doug.meal_entries.order(:id).last.quantity_grams.to_f
  end

  # Most of `foods` is still names the chat invented with no macros behind them. There
  # is nothing to put on the screen for one of those, so it says so rather than
  # rendering a row of blanks.
  test "a food with no macros sends you back rather than showing blanks" do
    nameless = foods(:chicken_bowl)

    get food_path(nameless)

    assert_redirected_to repeats_path
    assert_match "chicken burrito bowl", flash[:alert]
  end

  test "a zero portion is refused rather than logged" do
    assert_no_difference -> { MealEntry.count } do
      post log_food_path(foods(:chicken_bowl)), params: { grams: 100 }
    end

    assert_redirected_to food_path(foods(:chicken_bowl))
  end
end
