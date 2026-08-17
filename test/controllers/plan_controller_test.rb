require "test_helper"

class PlanControllerTest < ActionDispatch::IntegrationTest
  # The plan is household reading, not a public page — it names the server, the
  # deploy paths, and the shared Drive folder.
  test "requires authentication" do
    get "/plan"

    assert_redirected_to new_session_path
  end

  test "renders the plan for a signed-in user" do
    sign_in_as users(:doug)

    get "/plan"

    assert_response :success
    assert_select "h1", "MacroTrack"
    assert_select "h2.wp", minimum: 5
  end

  # Status comes from the document itself, so a package marked done in the
  # markdown can't show as pending on the page.
  test "marks completed work packages as done" do
    sign_in_as users(:doug)

    get "/plan"

    assert_select ".chip--done", minimum: 3
    assert_select ".chip--next", 1
  end
end
