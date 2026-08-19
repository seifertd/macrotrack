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
      assert_select "h2##{anchor}, h3##{anchor}", 1, "no heading for nav entry ##{anchor}"
    end
  end

  # The document's own "Build order:" line is the authority. Heading order drifted from
  # it the first time a package was promoted and then demoted again, which left a
  # half-finished WP6 claiming to be the work in progress while WP4 — finished, and
  # sitting below it in the prose — was still counted as ahead of it.
  test "the nav follows the build order, not the order sections happen to sit in" do
    sign_in_as users(:doug)

    get "/plan"

    labels = css_select(".toc__num").map(&:text)

    assert_equal %w[ WP1 WP2 WP3 WP6a WP4 WP4.5 ], labels.first(6)
    assert_operator labels.index("WP6b"), :>, labels.index("WP4.5"), "6b is scheduled after 4.5"
  end

  # WP6 is a container for two halves with different states. Listing it as a package
  # meant a done half and a pending half averaging out into one misleading chip.
  test "a package split into halves is listed as its halves, not as a container" do
    sign_in_as users(:doug)

    get "/plan"

    labels = css_select(".toc__num").map(&:text)

    assert_includes labels, "WP6a"
    assert_includes labels, "WP6b"
    assert_not_includes labels, "WP6"
    assert_select "h2#wp6.wp--group", 1, "the container still needs an anchor to link to"
    assert_select "h2#wp6 .chip", 0
  end

  # Exactly one package can be next, and it must be the first unfinished one the build
  # order calls for — not the first unfinished heading in the document.
  test "next up is the first unfinished package in build order" do
    sign_in_as users(:doug)

    get "/plan"

    assert_select ".chip--next", 1
    assert_select "h2#wp4-5 .chip--next", 1
  end
end
