require "test_helper"

class Met::TableTest < ActiveSupport::TestCase
  test "burn is met times weight times hours" do
    # Running, moderate = 9.8 MET. 9.8 * 70 kg * 0.5 h = 343 kcal.
    assert_equal 343.0, Met::Table.calories_for(
      activity: "running", intensity: "moderate", minutes: 30, weight_kg: 70
    )
  end

  test "intensity moves the number in the right direction" do
    burns = %w[ light moderate vigorous ].map do |intensity|
      Met::Table.calories_for(activity: "cycling", intensity: intensity, minutes: 60, weight_kg: 70)
    end

    assert_equal burns.sort, burns
  end

  test "an unknown activity falls back rather than refusing" do
    assert_operator Met::Table.calories_for(
      activity: "jazzercise", intensity: "moderate", minutes: 45, weight_kg: 70
    ), :>, 0
  end

  test "a described activity still finds its row" do
    assert_equal Met::Table.met_for("running", "moderate"), Met::Table.met_for("trail running", "moderate")
  end

  test "no weight on file uses the default rather than returning nothing" do
    assert_equal Met::Table.calories_for(activity: "walking", intensity: "moderate", minutes: 60),
      Met::Table.calories_for(activity: "walking", intensity: "moderate", minutes: 60,
        weight_kg: Met::Table::DEFAULT_WEIGHT_KG)
  end
end
