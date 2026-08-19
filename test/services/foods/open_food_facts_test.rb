require "test_helper"

class Foods::OpenFoodFactsTest < ActiveSupport::TestCase
  # A trimmed real response shape: v2 with `fields=` returns exactly the keys asked for,
  # and `nutriments` carries the four numbers under `_100g` suffixes.
  YOGURT = {
    "status" => 1,
    "product" => {
      "code" => "0070470496740",
      "product_name" => "Black Cherry Yogurt",
      "brands" => "Oui by Yoplait,General Mills",
      "nutriments" => {
        "energy-kcal_100g" => 123.0, "proteins_100g" => 3.5,
        "carbohydrates_100g" => 16.9, "fat_100g" => 4.9
      }
    }
  }.freeze

  test "creates a food from a hit, brand first" do
    food = stubbing("0070470496740" => YOGURT) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_equal "Oui by Yoplait Black Cherry Yogurt", food.name
    assert_equal "0070470496740", food.barcode
    assert_equal "openfoodfacts", food.source
    assert_equal 123.0, food.calories_per_100g.to_f
    assert_equal 3.5, food.protein_per_100g.to_f
    assert_equal 16.9, food.carbs_per_100g.to_f
    assert_equal 4.9, food.fat_per_100g.to_f
  end

  test "does not repeat the brand when the name already carries it" do
    product = YOGURT.deep_dup
    product["product"]["product_name"] = "Oui by Yoplait Black Cherry"

    food = stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_equal "Oui by Yoplait Black Cherry", food.name
  end

  test "answers from our own table without calling out" do
    existing = Food.create!(name: "Already Known", barcode: "0070470496740",
      source: "openfoodfacts", calories_per_100g: 100)

    # No stub registered: the test adapter raises on any unstubbed request, so reaching
    # the network here would fail rather than pass quietly.
    food = stubbing({}) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_equal existing, food
  end

  test "a scan of a barcode nobody has is a miss, not an error" do
    food = stubbing("0000000000000" => { "status" => 0 }) { Foods::OpenFoodFacts.find("0000000000000") }

    assert_nil food
    assert_nil Food.find_by(barcode: "0000000000000")
  end

  test "a product with no energy figure is a miss — there is nothing to log" do
    product = YOGURT.deep_dup
    product["product"]["nutriments"] = { "proteins_100g" => 3.5 }

    assert_nil stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }
  end

  test "a product with no name is a miss" do
    product = YOGURT.deep_dup
    product["product"]["product_name"] = ""

    assert_nil stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }
  end

  test "captures the serving weight and the label it came from" do
    product = YOGURT.deep_dup
    product["product"]["serving_quantity"] = 115
    product["product"]["serving_size"] = "0.5 cup (115 g)"

    food = stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_equal 115, food.serving_g.to_f
    assert_equal "0.5 cup (115 g)", food.serving_label
  end

  test "a product that states no serving stays in grams" do
    food = stubbing("0070470496740" => YOGURT) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_nil food.serving_g
    assert_nil food.serving_label
  end

  test "a nonsense serving quantity is ignored rather than stored" do
    product = YOGURT.deep_dup
    product["product"]["serving_quantity"] = "unknown"

    food = stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_nil food.serving_g
  end

  test "refresh_serving fills in a row stored before the column existed" do
    food = Food.create!(name: "Knudsen cottage cheese", barcode: "0070470496740",
      source: "openfoodfacts", calories_per_100g: 93.22)
    product = YOGURT.deep_dup
    product["product"]["serving_quantity"] = 115
    product["product"]["serving_size"] = "0.5 cup (115 g)"

    stubbing("0070470496740" => product) { Foods::OpenFoodFacts.refresh_serving(food) }

    assert_equal 115, food.reload.serving_g.to_f
    assert_equal "0.5 cup (115 g)", food.serving_label
    assert_equal 93.22, food.calories_per_100g.to_f, "nutrition is left alone"
  end

  test "refresh_serving leaves a row alone when upstream has no serving either" do
    food = Food.create!(name: "Mystery", barcode: "0070470496740",
      source: "openfoodfacts", calories_per_100g: 100)

    assert_nil stubbing("0070470496740" => YOGURT) { Foods::OpenFoodFacts.refresh_serving(food) }
    assert_nil food.reload.serving_g
  end

  test "falls back to kilojoules when kcal is missing" do
    product = YOGURT.deep_dup
    product["product"]["nutriments"] = { "energy-kj_100g" => 515.0 }

    food = stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_in_delta 123.09, food.calories_per_100g.to_f, 0.01, "515 kJ is 123 kcal"
  end

  test "keeps a genuine zero rather than reading it as missing" do
    product = YOGURT.deep_dup
    product["product"]["nutriments"] = { "energy-kcal_100g" => 0.0, "fat_100g" => 0.0 }

    food = stubbing("0070470496740" => product) { Foods::OpenFoodFacts.find("0070470496740") }

    assert_equal 0.0, food.calories_per_100g.to_f, "a diet soda really is 0 kcal/100g"
    assert_equal 0.0, food.fat_per_100g.to_f
    assert_nil food.protein_per_100g, "absent is not the same answer as zero"
  end

  test "a network failure is a miss, not a 500" do
    connection = Faraday.new do |f|
      f.adapter(:test) { |stub| stub.get(/.*/) { raise Faraday::ConnectionFailed, "down" } }
    end

    assert_nil Foods::OpenFoodFacts.with_connection(connection) { Foods::OpenFoodFacts.find("0070470496740") }
  end

  test "an upstream error response is a miss" do
    connection = Faraday.new do |f|
      f.adapter(:test) { |stub| stub.get(/.*/) { [ 503, {}, "" ] } }
    end

    assert_nil Foods::OpenFoodFacts.with_connection(connection) { Foods::OpenFoodFacts.find("0070470496740") }
  end

  test "normalizes what a scanner or a person actually produces" do
    assert_equal "0070470496740", Foods::OpenFoodFacts.normalize("  0070470496740 ")
    assert_equal "0070470496740", Foods::OpenFoodFacts.normalize("0-070470-496740")
    assert_equal "00123456", Foods::OpenFoodFacts.normalize("00123456"), "leading zeros survive"
  end

  test "rejects anything outside barcode length, so it can never build a bad URL" do
    assert_nil Foods::OpenFoodFacts.normalize("12345")
    assert_nil Foods::OpenFoodFacts.normalize("123456789012345")
    assert_nil Foods::OpenFoodFacts.normalize("not a barcode")
    assert_nil Foods::OpenFoodFacts.normalize(nil)
  end

  private
    # Each key is a barcode; the value is the JSON body the API would return for it.
    def stubbing(responses)
      connection = Faraday.new do |f|
        f.adapter :test do |stub|
          responses.each do |barcode, body|
            stub.get("/api/v2/product/#{barcode}.json") { [ 200, { "Content-Type" => "application/json" }, body.to_json ] }
          end
        end
      end

      Foods::OpenFoodFacts.with_connection(connection) { yield }
    end
end
