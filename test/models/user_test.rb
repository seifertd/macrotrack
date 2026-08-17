require "test_helper"

class UserTest < ActiveSupport::TestCase
  setup do
    @user = users(:doug)
  end

  test "local_date resolves a UTC timestamp into the user's own zone" do
    assert_equal Date.new(2026, 8, 16), @user.local_date(Time.utc(2026, 8, 17, 6, 30))
    assert_equal Date.new(2026, 8, 17), @user.local_date(Time.utc(2026, 8, 17, 15, 30))
  end

  # The bug this guards against: both fixtures are stamped 2026-08-17 in UTC, but the
  # 06:30 UTC one is 23:30 the previous evening in Los Angeles. Splitting on UTC midnight
  # would file a late-night snack on the wrong day, and "what day was this" is the product.
  test "day_totals splits on local midnight, not UTC midnight" do
    assert_equal 300, @user.day_totals(Date.new(2026, 8, 16))[:calories].to_i
    assert_equal 500, @user.day_totals(Date.new(2026, 8, 17))[:calories].to_i
  end

  test "day_totals accepts a Time and resolves it to that local day" do
    assert_equal 300, @user.day_totals(Time.utc(2026, 8, 17, 6, 30))[:calories].to_i
    assert_equal 500, @user.day_totals(Time.utc(2026, 8, 17, 15, 30))[:calories].to_i
  end

  test "day_totals sums every macro column" do
    totals = @user.day_totals(Date.new(2026, 8, 17))

    assert_equal 30, totals[:protein_g].to_i
    assert_equal 20, totals[:fat_g].to_i
    assert_equal 45, totals[:carbs_g].to_i
  end

  test "day_totals returns zeroes rather than nils for an empty day" do
    totals = @user.day_totals(Date.new(2020, 1, 1))

    assert_equal [ 0, 0, 0, 0 ], User::TOTAL_COLUMNS.map { |column| totals[column].to_i }
  end

  test "calories_remaining goes negative when over target" do
    assert_equal 1500, @user.calories_remaining(Date.new(2026, 8, 17))

    @user.update!(daily_calorie_target: 400)
    assert_equal(-100, @user.calories_remaining(Date.new(2026, 8, 17)))
  end

  test "household_members is everyone else sharing the kitchen" do
    assert_equal [ users(:partner) ], @user.household_members.to_a
  end

  # The thing that would break if this were written as "the other user": a third
  # person joining must widen the list, not raise or silently pick someone.
  test "household_members grows when someone joins" do
    third = households(:seifert).users.create!(
      name: "Kid", email_address: "kid@example.com", password: "password"
    )

    assert_equal [ third, users(:partner) ], @user.household_members.to_a  # ordered by name
  end

  test "household_members excludes people in other households" do
    assert_not_includes @user.household_members, users(:neighbor)
    assert_equal [], users(:neighbor).household_members.to_a
  end

  test "household_member_named resolves a name the assistant heard" do
    assert_equal users(:partner), @user.household_member_named("partner")
    assert_equal users(:partner), @user.household_member_named("  Partner ")
    assert_nil @user.household_member_named("Neighbor")
  end

  test "timezone must be a real zone" do
    @user.timezone = "Mars/Olympus_Mons"
    assert_not @user.valid?
    assert_includes @user.errors.attribute_names, :timezone
  end
end
