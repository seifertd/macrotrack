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

  # The nav is the point of the page for anyone not reading top to bottom, so
  # every entry needs a link and every link needs a heading to land on.
  test "lists every work package in the nav with a working anchor" do
    sign_in_as users(:doug)

    get "/plan"

    anchors = css_select(".toc__link").map { |link| link["href"].delete_prefix("#") }

    assert_operator anchors.size, :>=, 10
    assert_includes anchors, "wp4-5", "decimal package numbers must get a usable anchor"

    anchors.each do |anchor|
      assert_select "h2##{anchor}", 1, "no heading for nav entry ##{anchor}"
    end
  end
end
