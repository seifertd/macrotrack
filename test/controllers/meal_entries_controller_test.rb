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
    def entry_params(overrides = {})
      {
        food_name: "oatmeal", calories: 320, protein_g: 12, fat_g: 6, carbs_g: 54,
        quantity_grams: 250, meal_type: "breakfast", consumed_at: "2026-08-17T08:30"
      }.merge(overrides)
    end
end
