require "test_helper"

class MealEntriesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:doug)
    sign_in_as @user
  end

  # Submitting "23:30" means 23:30 where the user is standing. If the request ran in UTC
  # the entry would be created on the following day and vanish from the day they logged it.
  test "creating an entry parses the submitted time in the user's zone" do
    assert_difference -> { @user.meal_entries.count }, 1 do
      post meal_entries_path, params: { meal_entry: entry_params(consumed_at: "2026-08-16T23:30") }
    end

    entry = @user.meal_entries.order(:created_at).last

    assert_equal Time.utc(2026, 8, 17, 6, 30), entry.consumed_at
    assert_equal Date.new(2026, 8, 16), @user.local_date(entry.consumed_at)
    assert_redirected_to day_path(Date.new(2026, 8, 16))
  end

  # The add screen is reached from the header, so it has to work on whatever day the
  # header was showing — not just today.
  test "the add screen offers all four ways in" do
    get new_meal_entry_path

    assert_response :success
    assert_select "a[href=?]", chat_path
    assert_select "a[href=?]", scan_path
    assert_select "a[href=?]", repeats_path
    assert_select "input[type=submit][value=?]", "Log it"
  end

  test "the add screen prefills now on today" do
    get new_meal_entry_path

    assert_response :success
    assert_equal @user.local_today, assigns_consumed_at.to_date
  end

  # "Now" on a day that ended days ago is a plausible-looking wrong answer: it would be
  # accepted unedited. Noon reads as the placeholder it is.
  test "the add screen prefills noon on a past day" do
    date = Date.new(2026, 8, 16)
    get new_meal_entry_path(date: date)

    assert_response :success
    assert_equal date, assigns_consumed_at.to_date
    assert_equal 12, assigns_consumed_at.hour
  end

  test "the add screen falls back to today on an unparseable date" do
    get new_meal_entry_path(date: "9999-99-99")

    assert_response :success
    assert_equal @user.local_today, assigns_consumed_at.to_date
  end

  # The day page's own Add button has to carry the day being viewed, or logging from a
  # past day silently lands on today.
  test "the header Add button carries the day on screen" do
    get day_path(Date.new(2026, 8, 16))
    assert_select "header a[href=?]", new_meal_entry_path(date: Date.new(2026, 8, 16))

    get root_path
    assert_select "header a[href=?]", new_meal_entry_path(date: @user.local_today)
  end

  test "the header Add button is hidden on the add screen itself" do
    get new_meal_entry_path
    assert_select "header a[href^=?]", new_meal_entry_path, count: 0
  end

  # A rejected entry used to land on today with an alert, losing both the screen the form
  # was on and the day it was for.
  test "an invalid entry returns to the add screen for the day it was for" do
    post meal_entries_path, params: { meal_entry: entry_params(calories: -50, consumed_at: "2026-08-16T20:00") }

    assert_redirected_to new_meal_entry_path(date: Date.new(2026, 8, 16))
  end

  test "creating an entry marks it manual and attaches a shared food row" do
    post meal_entries_path, params: { meal_entry: entry_params }
    entry = @user.meal_entries.order(:created_at).last

    assert_equal "manual", entry.source
    assert_equal "oatmeal", entry.food.name
  end

  test "an existing food is reused rather than duplicated" do
    assert_no_difference -> { Food.count } do
      post meal_entries_path, params: { meal_entry: entry_params(food_name: "Chicken Burrito Bowl") }
    end
  end

  test "an invalid entry does not create anything" do
    assert_no_difference -> { MealEntry.count } do
      post meal_entries_path, params: { meal_entry: entry_params(calories: -50) }
    end
  end

  test "one member cannot reach the other member's entries" do
    other = users(:partner).meal_entries.create!(
      source: "manual", calories: 100, consumed_at: Time.current
    )

    get edit_meal_entry_path(other)
    assert_response :not_found

    assert_no_difference -> { MealEntry.count } do
      delete meal_entry_path(other)
    end
  end

  # An entry logged at 10:29:13 used to render as "10:29:13" in the datetime-local field.
  # The browser's step of one minute then measured from :13, so a round "10:30" was
  # rejected as invalid. Mobile date-time pickers offer no seconds control, so no
  # reachable value satisfied the check and the entry could not be edited from a phone.
  test "the edit screen offers a whole minute so a round time is accepted" do
    entry = @user.meal_entries.create!(
      source: "manual", calories: 100, consumed_at: Time.utc(2026, 8, 17, 15, 29, 13)
    )

    get edit_meal_entry_path(entry)

    assert_response :success
    assert_select "input[name=?]", "meal_entry[consumed_at]" do |input|
      assert_no_match(/:\d\d:\d\d\z/, input.first["value"])
    end
  end

  test "updating an entry keeps it scoped and redirects to its day" do
    entry = @user.meal_entries.create!(
      source: "manual", calories: 100, consumed_at: Time.utc(2026, 8, 17, 15, 30)
    )

    patch meal_entry_path(entry), params: { meal_entry: entry_params(calories: 777) }

    assert_equal 777, entry.reload.calories.to_i
    assert_redirected_to day_path(Date.new(2026, 8, 17))
  end

  test "deleting an entry removes it" do
    entry = @user.meal_entries.create!(
      source: "manual", calories: 100, consumed_at: Time.utc(2026, 8, 17, 15, 30)
    )

    assert_difference -> { @user.meal_entries.count }, -1 do
      delete meal_entry_path(entry)
    end
  end

  test "signed out requests are sent to the sign in page" do
    sign_out
    post meal_entries_path, params: { meal_entry: entry_params }

    assert_redirected_to new_session_path
  end

  private
    # The prefilled "When" field, read back out of the rendered form.
    def assigns_consumed_at
      value = css_select("input[name='meal_entry[consumed_at]']").first[:value]
      Time.use_zone(@user.timezone) { Time.zone.parse(value) }
    end

    def entry_params(overrides = {})
      {
        food_name: "oatmeal", calories: 320, protein_g: 12, fat_g: 6, carbs_g: 54,
        quantity_grams: 250, meal_type: "breakfast", consumed_at: "2026-08-17T08:30"
      }.merge(overrides)
    end
end
