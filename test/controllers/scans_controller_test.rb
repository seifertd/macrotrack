require "test_helper"

class ScansControllerTest < ActionDispatch::IntegrationTest
  BARCODE = "0070470496740".freeze

  setup do
    @doug = users(:doug)
    sign_in_as @doug

    # No test touches the real OpenFoodFacts. The default here answers "no such product"
    # for everything, which is the interesting branch; tests that need a hit stub their
    # own, and `offline!` proves a lookup never left the building.
    Foods::OpenFoodFacts.connection = stub_connection { [ 200, {}, { status: 0 }.to_json ] }
  end

  teardown { Foods::OpenFoodFacts.reset_connection! }

  test "requires a signed-in user" do
    sign_out
    get scan_path

    assert_redirected_to new_session_path
  end

  test "the scan screen offers the typed fallback as well as the camera" do
    get scan_path

    assert_response :success
    assert_select "[data-controller=barcode]"
    assert_select "form[action=?][method=get]", lookup_scan_path
    assert_select "input[name=barcode]"
  end

  test "typing a number sends you to its lookup" do
    get lookup_scan_path, params: { barcode: "0-070470-496740" }

    assert_redirected_to scanned_path(BARCODE)
  end

  test "typing something that isn't a barcode says so instead of 404ing" do
    get lookup_scan_path, params: { barcode: "12" }

    assert_redirected_to scan_path
    assert_equal "That didn't look like a barcode.", flash[:alert]
  end

  test "a known barcode goes straight to the portion screen" do
    food = known_food

    get scanned_path(BARCODE)

    assert_response :success
    assert_select "h1", text: food.name
    assert_select "input[name=grams][value=?]", FoodPortion::REFERENCE_GRAMS.to_s
    assert_select "form[action=?]", log_scan_path(BARCODE)
    assert_select "input[type=submit][value=?]", "Log it"
  end

  test "an unknown barcode offers manual entry rather than a dead end" do
    get scanned_path("0000000000000")

    assert_response :success
    assert_select "form[action=?]", adopt_scan_path("0000000000000")
    assert_select "input[name=?]", "food[calories_per_100g]"
  end

  test "logging a portion writes it onto your own day and says what it came to" do
    known_food

    assert_difference -> { @doug.meal_entries.count }, 1 do
      post log_scan_path(BARCODE), params: { grams: 150 }
    end

    entry = @doug.meal_entries.order(:created_at).last
    assert_equal "barcode", entry.source
    assert_equal 150, entry.quantity_grams.to_f
    assert_in_delta 184.5, entry.calories.to_f, 0.01
    assert_redirected_to day_path(@doug.local_date(entry.consumed_at))
    assert_match(/185 kcal/, flash[:notice])
  end

  test "adopting an unknown barcode saves it against that number for next time" do
    assert_difference -> { Food.count }, 1 do
      post adopt_scan_path("0000000000000"), params: {
        food: { name: "Store Brand Oats", calories_per_100g: 379,
                protein_per_100g: 13.2, carbs_per_100g: 67.7, fat_per_100g: 6.5 }
      }
    end

    food = Food.find_by(barcode: "0000000000000")
    assert_equal "Store Brand Oats", food.name
    assert_equal "user_custom", food.source
    assert_redirected_to scanned_path("0000000000000")
  end

  test "an adopted product is found without calling out on the next scan" do
    post adopt_scan_path("0000000000000"), params: {
      food: { name: "Store Brand Oats", calories_per_100g: 379 }
    }

    offline!
    get scanned_path("0000000000000")

    assert_response :success
    assert_select "h1", text: "Store Brand Oats"
  end

  test "adopting without a name comes back with the error rather than saving" do
    assert_no_difference -> { Food.count } do
      post adopt_scan_path("0000000000000"), params: { food: { name: "", calories_per_100g: 379 } }
    end

    assert_response :unprocessable_entity
    assert_select "body", text: /Name can't be blank/
  end

  private
    def stub_connection(&response)
      Faraday.new { |f| f.adapter(:test) { |stub| stub.get(/.*/, &response) } }
    end

    # Any lookup that reaches the network from here fails the test rather than passing
    # quietly — the point being that the row was answered from our own table.
    def offline!
      Foods::OpenFoodFacts.connection = stub_connection { raise "OpenFoodFacts was called" }
    end

    def known_food
      Food.create!(name: "Oui Black Cherry Yogurt", barcode: BARCODE, source: "openfoodfacts",
        calories_per_100g: 123, protein_per_100g: 3.5, carbs_per_100g: 16.9, fat_per_100g: 4.9)
    end
end
