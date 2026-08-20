require "test_helper"

class RepeatsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @doug = users(:doug)
    @partner = users(:partner)
    sign_in_as @doug
  end

  test "requires a signed-in user" do
    sign_out
    get repeats_path

    assert_redirected_to new_session_path
  end

  test "lists what both of you have eaten lately, newest first" do
    mine = log(@doug, "my lunch", consumed_at: 3.hours.ago)
    theirs = log(@partner, "their dinner", consumed_at: 1.hour.ago)

    get repeats_path

    assert_response :success
    assert_select "body", text: /their dinner/
    assert_select "body", text: /my lunch/
    assert_operator response.body.index("their dinner"), :<, response.body.index("my lunch"),
      "newest first"
    assert_select "a[href=?]", repeat_path(theirs)
    assert_select "a[href=?]", repeat_path(mine)
  end

  test "shows one row per food, however often it was eaten" do
    food = Food.find_or_create_by_name("chilli")
    eaten = 3.times.map { |n| log(@doug, "chilli", food: food, consumed_at: n.days.ago) }

    get repeats_path

    # Counted against the three entries rather than every link on the page: the fixtures
    # carry their own recent meals, and those legitimately belong in the picker too.
    shown = eaten.count { |entry| response.body.include?(repeat_path(entry)) }
    assert_equal 1, shown
  end

  test "does not offer another household's meals" do
    theirs = log(users(:neighbor), "not yours")

    get repeats_path
    assert_select "body", { text: /not yours/, count: 0 }

    get repeat_path(theirs)
    assert_response :not_found
  end

  test "leaves out anything older than the window" do
    log(@doug, "ancient", consumed_at: 60.days.ago)

    get repeats_path

    assert_select "body", { text: /ancient/, count: 0 }
  end

  # WP4.4. The gap this closes: an imported recipe has no entry behind it, so until the
  # search box existed it was reachable by name in the chat and nowhere else.
  test "a food nobody has eaten is findable by name" do
    juice = magic_juice

    get repeats_path
    assert_select "body", { text: /Magic Juice/, count: 0 }, "unsearched, the list is what got eaten"

    get repeats_path, params: { q: "magic juice" }

    assert_response :success
    assert_select "a[href=?]", food_path(juice, q: "magic juice")
  end

  test "a half-typed name still finds it" do
    magic_juice

    get repeats_path, params: { q: "mag" }

    assert_select "body", text: /Magic Juice/
  end

  test "a typo still finds it" do
    magic_juice

    get repeats_path, params: { q: "magik juice" }

    assert_select "body", text: /Magic Juice/
  end

  test "a food with no macros is never offered, because there is nothing to portion" do
    Food.create!(name: "Nameless Stew", source: "user_custom")

    get repeats_path, params: { q: "nameless stew" }

    assert_select "body", { text: /Nameless Stew/, count: 0 }
  end

  # A plate somebody really ate beats a serving size, so the entry takes the slot and
  # the food does not appear twice under two different headings.
  test "a food that has been eaten appears once, as the entry" do
    juice = magic_juice
    entry = log(@doug, "Magic Juice", food: juice, quantity_grams: 240)

    get repeats_path, params: { q: "magic" }

    assert_select "a[href=?]", repeat_path(entry)
    assert_select "a[href^=?]", "/foods/", count: 0
  end

  # Searching says which meal you want. Browsing does not, which is what the 30-day
  # window keeps short.
  test "searching reaches back past the window that browsing stops at" do
    log(@doug, "ancient chowder", consumed_at: 60.days.ago)

    get repeats_path
    assert_select "body", { text: /ancient chowder/, count: 0 }

    get repeats_path, params: { q: "chowder" }
    assert_select "body", text: /ancient chowder/
  end

  test "searching still cannot see another household's meals" do
    log(users(:neighbor), "secret casserole")

    get repeats_path, params: { q: "secret casserole" }

    assert_select "body", { text: /secret casserole/, count: 0 }
  end

  # The similarity ordering builds a fragment of SQL around the query, which is exactly
  # where a stray quote goes wrong.
  test "a quote in the query is searched for, not executed" do
    magic_juice
    Food.create!(name: "O'Brien Potatoes", source: "user_custom", calories_per_100g: 149)

    get repeats_path, params: { q: "o'brien" }

    assert_response :success
    assert_select "body", text: /O'Brien Potatoes/
  end

  test "a search that matches nothing points at the chat rather than dead-ending" do
    get repeats_path, params: { q: "wombat wellington" }

    assert_response :success
    assert_select "a[href=?]", chat_path
  end

  test "the portion screen defaults to the source portion" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559)

    get repeat_path(source)

    assert_response :success
    assert_select "input[name=grams][value=?]", "360"
    assert_select "input[type=submit][value=?]", "Log it"
  end

  # You can pick from anyone's plate in the household; you can only log onto your own.
  # The chat's copy_to_household_member is the one place another person's day can be
  # written to, and it makes you name them.
  test "the portion screen offers no way to log onto somebody else's day" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559)

    get repeat_path(source)

    assert_select "[name=target_id]", count: 0
    assert_select "input[type=submit]", count: 1
  end

  test "an unweighed source offers multipliers instead of a grams field" do
    source = log(@partner, "their dinner", quantity_grams: nil, calories: 500)

    get repeat_path(source)

    assert_select "input[name=grams]", count: 0
    assert_select "input[name=multiplier]", count: 1
  end

  test "logging a half portion writes a scaled copy onto my day" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559, protein_g: 30)

    assert_difference -> { @doug.meal_entries.count }, 1 do
      post log_repeat_path(source), params: { grams: 180 }
    end

    entry = @doug.meal_entries.order(:id).last
    assert_equal 279.5, entry.calories.to_f
    assert_equal 15.0, entry.protein_g.to_f
    assert_equal "copied", entry.source
    assert_redirected_to day_path(@doug.local_today)
  end

  # A stray or forged target_id must not be able to steer the write. The parameter is
  # gone rather than validated, which is the version that cannot come back wrong.
  test "a target_id in the params changes nothing" do
    source = log(@partner, "their dinner", quantity_grams: 400, calories: 800)

    assert_no_difference -> { @partner.meal_entries.count } do
      assert_difference -> { @doug.meal_entries.count }, 1 do
        post log_repeat_path(source), params: { grams: 200, target_id: @partner.id }
      end
    end

    assert_equal 0, users(:neighbor).meal_entries.count
  end

  private
    def magic_juice
      @magic_juice ||= Food.create!(name: "Magic Juice", source: "user_custom",
        calories_per_100g: 71.87, protein_per_100g: 0.4, carbs_per_100g: 17.2,
        fat_per_100g: 0.1, serving_g: 226.8)
    end

    def log(user, name, food: nil, consumed_at: 1.hour.ago, quantity_grams: 300, **attributes)
      user.meal_entries.create!({
        source: "manual", consumed_at: consumed_at, quantity_grams: quantity_grams,
        calories: 500, protein_g: 20, fat_g: 15, carbs_g: 40,
        food: food || Food.find_or_create_by_name(name)
      }.merge(attributes))
    end
end
