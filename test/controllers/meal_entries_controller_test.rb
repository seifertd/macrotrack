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

  # The same failure one column over, and from the same cause: a step the browser can
  # round to, over a column that does not round. Every macro is a decimal, and only the
  # ones typed into this form arrive whole — an entry logged off a food is a per-100g
  # figure scaled by a portion, so 28g of havarti is 108.45 kcal. The edit screen refused
  # to save the number it had just rendered: "the two nearest valid values are 108 and 109".
  test "the edit screen accepts the decimals the row was saved with" do
    entry = @user.meal_entries.create!(
      source: "matched", consumed_at: Time.utc(2026, 8, 17, 15, 30),
      calories: 108.45, quantity_grams: 28, protein_g: 6.42, fat_g: 9.03, carbs_g: 0.19
    )

    get edit_meal_entry_path(entry)

    assert_response :success
    %w[ calories quantity_grams protein_g fat_g carbs_g ].each do |field|
      assert_select "input[name=?][step=?]", "meal_entry[#{field}]", "any"
      # A numeric keypad has no decimal point on it, so the field would be unfixable
      # by hand even once the browser stopped refusing it.
      assert_select "input[name=?][inputmode=?]", "meal_entry[#{field}]", "decimal"
    end
  end

  # Nothing that logs off a food asks which meal it was, so the edit form shows its blank
  # option — which posts "" and used to fail the inclusion check. The screen for fixing an
  # entry has to be able to save one it did not create.
  test "an entry with no meal type saves without being made to pick one" do
    entry = @user.meal_entries.create!(
      source: "matched", consumed_at: Time.utc(2026, 8, 17, 15, 30), calories: 108.45
    )
    assert_nil entry.meal_type

    patch meal_entry_path(entry), params: { meal_entry: entry_params(meal_type: "") }

    assert_redirected_to day_path(Date.new(2026, 8, 17))
    assert_nil entry.reload.meal_type
  end

  test "a fractional figure survives the round trip through the form" do
    entry = @user.meal_entries.create!(
      source: "matched", consumed_at: Time.utc(2026, 8, 17, 15, 30), calories: 108.45
    )

    patch meal_entry_path(entry),
      params: { meal_entry: entry_params(calories: "121.9", protein_g: "6.42", quantity_grams: "31.5") }

    entry.reload
    assert_equal 121.9, entry.calories.to_f
    assert_equal 6.42, entry.protein_g.to_f
    assert_equal 31.5, entry.quantity_grams.to_f
  end

  test "updating an entry keeps it scoped and redirects to its day" do
    entry = @user.meal_entries.create!(
      source: "manual", calories: 100, consumed_at: Time.utc(2026, 8, 17, 15, 30)
    )

    patch meal_entry_path(entry), params: { meal_entry: entry_params(calories: 777) }

    assert_equal 777, entry.reload.calories.to_i
    assert_redirected_to day_path(Date.new(2026, 8, 17))
  end

  # The crash this replaced: `update` re-renders :edit, and the header link resolved a day
  # from the consumed_at the failed validation had just left nil — a 500 thrown over the
  # top of the error message it was rendering in order to explain itself.
  test "a blank When is reported rather than crashing the screen that reports it" do
    entry = @user.meal_entries.create!(
      source: "manual", calories: 100, consumed_at: Time.utc(2026, 8, 17, 15, 30)
    )

    patch meal_entry_path(entry), params: { meal_entry: entry_params(consumed_at: "") }

    assert_response :unprocessable_entity
    assert_select "li", text: /Consumed at can.t be blank/
    assert_select "a", text: "Back"
    assert_equal Time.utc(2026, 8, 17, 15, 30), entry.reload.consumed_at
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

  # WP5-b: one tap from this screen to a recording, which means the form posts the audio
  # itself rather than sending you to the chat screen to start again.
  test "the add screen records straight into the voice endpoint" do
    get new_meal_entry_path

    assert_select "form[action=?][data-turbo=?]", voice_entries_path, "false" do
      assert_select "input[type=file][name=?]", "voice_entry[audio]"
      assert_select "button[data-action=?]", "dictation#toggle"
    end
    # Nothing is sent on a timer: finishing is a press, and so is giving up.
    assert_select "button[data-action=?]", "dictation#finish"
    assert_select "button[data-action=?]", "dictation#cancel"
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
