require "test_helper"

class DaysControllerTest < ActionDispatch::IntegrationTest
  test "unauthenticated requests go to the sign in page" do
    get root_path
    assert_redirected_to new_session_path
  end

  test "root shows the signed in user's day" do
    sign_in_as users(:doug)
    get root_path

    assert_response :success
    assert_select "h1", "Today"
  end

  test "a dated day shows only that local day's entries" do
    sign_in_as users(:doug)
    get day_path(Date.new(2026, 8, 16))

    assert_response :success
    assert_select "h1", /16 August/
    assert_select "li", count: 1
  end

  # The bug this guards against: the header strip used to call day_totals with no
  # argument, so browsing to a past day showed that day's entries in the list and
  # today's numbers in the bar above them. A page that contradicts itself.
  test "the header strip totals the day being viewed, not today" do
    sign_in_as users(:doug)

    get day_path(Date.new(2026, 8, 16))
    assert_select "header" do
      assert_select "span", text: "300"
      assert_select "span", text: "1,700 left"
      assert_select "span", text: "16 Aug"      # says which day these numbers are
    end

    # Nothing in the header depends on hover: the macros are named in the legend and the
    # segments carry their own percentages, because on a phone there is no hover state.
    assert_select "header", /Protein/
    assert_select "header", /Fat/
    assert_select "header", /Carbs/

    get day_path(Date.new(2026, 8, 17))
    assert_select "header" do
      assert_select "span", text: "500"
      assert_select "span", text: "1,500 left"
    end
  end

  test "the header strip carries no date chip on today" do
    user = users(:doug)
    sign_in_as user

    get day_path(user.local_today)
    assert_select "header span", text: user.local_today.strftime("%-d %b"), count: 0
  end

  # Editing is reached from a day page, so the header should keep describing that day.
  test "the edit page header follows the entry's own day" do
    sign_in_as users(:doug)

    get edit_meal_entry_path(meal_entries(:doug_late_snack))
    assert_select "header" do
      assert_select "span", text: "300"
      assert_select "span", text: "16 Aug"
    end
  end

  # The route constraint only checks the shape, so a well-formed nonsense date still
  # reaches the controller. It should land on today rather than 500.
  test "an unparseable date falls back to today rather than erroring" do
    sign_in_as users(:doug)
    get "/days/9999-99-99"

    assert_response :success
    assert_select "h1", "Today"
  end
end
