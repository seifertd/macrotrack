require "test_helper"

class Meals::MatcherTest < ActiveSupport::TestCase
  setup do
    @doug = users(:doug)
    @partner = users(:partner)
  end

  test "finds a meal the household has eaten before, from a whole sentence" do
    entry = log(@partner, "Burst Cherry Tomato Pasta")

    match = Meals::Matcher.new(@doug, "I had the burst cherry tomato pasta again").best_entry

    assert_equal entry, match.entry
    assert_operator match.score, :>=, Meals::Matcher::THRESHOLD
  end

  test "matches across the household, not just my own entries" do
    entry = log(@partner, "IKEA meatballs with mashed potatoes, gravy & broccoli")

    assert_equal entry, Meals::Matcher.new(@doug, "leftover ikea meatballs for lunch").best_entry&.entry
  end

  test "does not reach into another household" do
    log(users(:neighbor), "Burst Cherry Tomato Pasta")

    assert_nil Meals::Matcher.new(@doug, "burst cherry tomato pasta").best_entry
  end

  test "does not reach past the window" do
    log(@partner, "Burst Cherry Tomato Pasta", consumed_at: 100.days.ago)

    assert_nil Meals::Matcher.new(@doug, "burst cherry tomato pasta").best_entry
  end

  test "punctuation in what was said is text, not SQL" do
    entry = log(@partner, "Burst Cherry Tomato Pasta")

    # A "?" in the text used to land in the SQL fragment and be counted as a bind
    # placeholder, so every question raised PreparedStatementInvalid before the query
    # was sent — which took the whole chat send down with it.
    [ "did I eat the burst cherry tomato pasta?", "burst cherry tomato pasta :name ?? ok" ].each do |text|
      assert_equal entry, Meals::Matcher.new(@doug, text).best_entry&.entry, text
    end

    assert_nothing_raised { Meals::Matcher.new(@doug, "what's for dinner? 100%_ '; --").hints }
  end

  test "unrelated food matches nothing" do
    log(@partner, "Burst Cherry Tomato Pasta")

    [ "sushi from the place down the road", "grilled salmon and rice", "a banana" ].each do |text|
      assert_nil Meals::Matcher.new(@doug, text).best_entry, text
    end
  end

  # The safety margin the threshold exists for. A correction is built out of the same
  # words as the thing it corrects, so it scores well on spelling similarity — "make
  # that double chicken" reaches 0.40 against *chicken burrito bowl*. Anything that
  # clears the bar here would silently log a second meal mid-correction.
  test "follow-up corrections stay under the suggestion threshold" do
    log(@doug, "chicken burrito bowl")
    log(@doug, "Pasta with tomatoes")

    [ "make that double chicken", "the pasta was bigger than that", "actually it was half that",
      "no, only a small bowl", "add butter to that", "scratch that", "delete that last one" ].each do |text|
      assert_nil Meals::Matcher.new(@doug, text).best_entry, "#{text.inspect} would have logged a meal"
    end
  end

  test "the most recent entry wins when the same food was eaten twice" do
    food = Food.find_or_create_by_name("Burst Cherry Tomato Pasta")
    log(@doug, nil, food: food, consumed_at: 5.days.ago)
    newest = log(@partner, nil, food: food, consumed_at: 1.hour.ago)

    assert_equal newest, Meals::Matcher.new(@doug, "burst cherry tomato pasta").best_entry.entry
  end

  test "hints include foods nobody has eaten yet, which entries alone would miss" do
    food = Food.find_or_create_by_name("Magic Juice")
    food.update!(calories_per_100g: 81.13, protein_per_100g: 3.53, fat_per_100g: 3.53, carbs_per_100g: 8.82)

    hints = Meals::Matcher.new(@doug, "I had a glass of magic juice").hints

    assert_equal [ "Magic Juice" ], hints.map(&:name)
    assert_not hints.first.entry?
    assert_nil Meals::Matcher.new(@doug, "I had a glass of magic juice").best_entry,
      "a food with no entry has no portion to offer, so it is a hint and not a suggestion"
  end

  test "hints ignore foods with no nutrition on file" do
    Food.find_or_create_by_name("Magic Juice")

    assert_empty Meals::Matcher.new(@doug, "magic juice").hints
  end

  test "hints reach lower than suggestions do, because a bad hint only costs a prompt line" do
    log(@doug, "chicken burrito bowl")

    matcher = Meals::Matcher.new(@doug, "make that double chicken")

    assert_nil matcher.best_entry
    assert_equal [ "chicken burrito bowl" ], matcher.hints.map(&:name)
  end

  test "blank input matches nothing" do
    log(@doug, "chicken burrito bowl")

    assert_nil Meals::Matcher.new(@doug, "  ").best_entry
    assert_empty Meals::Matcher.new(@doug, nil).hints
  end

  private
    def log(user, name, food: nil, consumed_at: 2.hours.ago)
      user.meal_entries.create!(
        source: "text", consumed_at: consumed_at, quantity_grams: 360, calories: 559,
        protein_g: 30, fat_g: 20, carbs_g: 50,
        food: food || Food.find_or_create_by_name(name)
      )
    end
end
