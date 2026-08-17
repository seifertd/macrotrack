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

  # The route constraint only checks the shape, so a well-formed nonsense date still
  # reaches the controller. It should land on today rather than 500.
  test "an unparseable date falls back to today rather than erroring" do
    sign_in_as users(:doug)
    get "/days/9999-99-99"

    assert_response :success
    assert_select "h1", "Today"
  end
end
