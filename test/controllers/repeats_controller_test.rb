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

  # The search answers while you type. That only works if what comes back is the list
  # alone: the box, its caret and the open keyboard are outside the frame the form
  # targets, so a keystroke never replaces anything being touched.
  test "the ranked list sits in a frame the search form targets" do
    juice = magic_juice

    get repeats_path(q: "magic juice")

    assert_select "form[data-turbo-frame=?]", "results"
    assert_select "input[name=q][data-action=?]", "input->search#submit"
    assert_select "turbo-frame#results a[href=?]", food_path(juice, q: "magic juice")
  end

  # Everything in that frame is a way off this screen, and none of those screens has a
  # frame by this name to hand back. Without `_top` a result would open into a hole.
  test "the results frame sends its own links to the top level" do
    get repeats_path(q: "magic juice")

    assert_select "turbo-frame#results[target=?]", "_top"
  end

  # The button is what the form does with no JavaScript, and this screen has to keep
  # working before the module has loaded — which on a phone opened from the home screen
  # is a real fraction of the time.
  test "the search still submits without the typing enhancement" do
    magic_juice

    get repeats_path
    assert_select "input[type=submit][value=?]", "Search"

    get repeats_path, params: { q: "magic juice" }
    assert_select "body", text: /Magic Juice/
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

  # The repeat screen renders shared/_portion_form, the same partial the scanner and the
  # food picker use. What made that possible is MealPortion answering chips/reference_grams
  # /reference_scaled like FoodPortion does, so this pins the multipliers the chips carry.
  test "the portion screen offers a share of the plate whether or not it was weighed" do
    [ 360, nil ].each do |quantity_grams|
      source = log(@partner, "their dinner", quantity_grams: quantity_grams, calories: 500)

      get repeat_path(source)

      assert_response :success
      MealPortion::MULTIPLIERS.each do |multiplier|
        assert_select "button[data-portion-target=chip][data-multiplier=?]", multiplier.to_s
      end
      assert_select "button[data-portion-target=chip]", count: MealPortion::MULTIPLIERS.length
    end
  end

  # Servings are a `foods` idea. Borrowing the food partial must not start claiming a
  # plate someone ate has one.
  test "the portion screen never claims a serving size for an entry" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559)

    get repeat_path(source)

    assert_select "p", text: /1 serving =/, count: 0
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

  # The complaint that prompted this: searching "portobello" put "Chicken soup with
  # portobello mushrooms and teriyaki chicken" above "Portobello Sandwich", because
  # word_similarity scores every name containing the query at 1.00 and the tie fell
  # through to alphabetical order.
  test "food matches come back best first, not alphabetically" do
    Food.create!(name: "Portobello Sandwich", calories_per_100g: 156, source: "user_custom")
    Food.create!(name: "Chicken soup with portobello mushrooms and teriyaki chicken",
      calories_per_100g: 40, source: "user_custom")
    Food.create!(name: "Aubergine and portobello bake", calories_per_100g: 90, source: "user_custom")

    get repeats_path(q: "portobello")

    assert_equal "Portobello Sandwich", first_named(/Portobello Sandwich|Chicken soup with portobello|Aubergine and portobello/)
    assert_match(/3 matches/, response.body, "every match is surfaced, not just the closest")
  end

  test "a name that is mostly the query beats a long one that merely contains it" do
    Food.create!(name: "Turkish Meatballs", calories_per_100g: 200, source: "user_custom")
    Food.create!(name: "15 Swedish meatballs with mashed potatoes, gravy and lingonberry",
      calories_per_100g: 150, source: "user_custom")

    get repeats_path(q: "meatballs")

    assert_equal "Turkish Meatballs", first_named(/Turkish Meatballs|15 Swedish meatballs/)
  end

  # Entries were ordered by recency even when the user had typed a name, so the meal they
  # asked for could sit below one they happened to eat later.
  test "entry matches are ordered by match, not by when they were eaten" do
    older = log(@doug, "Portobello Sandwich", consumed_at: 3.days.ago)
    newer = log(@doug, "Portobello mushroom sandwich on sourdough", consumed_at: 1.hour.ago)

    get repeats_path(q: "portobello sandwich")

    assert_operator response.body.index(repeat_path(older)), :<,
      response.body.index(repeat_path(newer)), "the one asked for, not the one eaten last"
  end

  test "browsing with no query is still most recent first" do
    older = log(@doug, "Older dinner", consumed_at: 3.days.ago)
    newest = log(@doug, "Tonight's dinner", consumed_at: 1.hour.ago)

    get repeats_path

    assert_operator response.body.index(repeat_path(newest)), :<, response.body.index(repeat_path(older))
  end

  # A "?" in the query is quoted into the ranking fragment, so it must not also be read
  # as a bind placeholder — the failure mode fixed in Meals::Matcher on the same day.
  test "punctuation in the query is text, not SQL" do
    Food.create!(name: "Portobello Sandwich", calories_per_100g: 156, source: "user_custom")

    get repeats_path(q: "portobello sandwich? 100% ';--")

    assert_response :success
  end

  # The complaint that produced the interleaving: searching "porto" *did* find the
  # imported Portobello Sandwich recipe, but it rendered under a second heading below a
  # chicken soup entry, so it looked like a miss. One list, best first, kind on the row.
  test "a recipe outranks a worse-matching meal that was actually eaten" do
    log(@doug, "Chicken soup with portobello mushrooms", consumed_at: 1.hour.ago)
    Food.create!(name: "Portobello Sandwich", calories_per_100g: 156, source: "recipe")

    get repeats_path(q: "porto")

    body = response.body
    assert_operator body.index("Portobello Sandwich"), :<, body.index("Chicken soup with portobello"),
      "the closer match comes first whichever kind of row it is"
    assert_match(/2 matches/, body)
  end

  test "each row says which kind it is" do
    log(@doug, "Chicken soup with portobello mushrooms", consumed_at: 1.hour.ago)
    Food.create!(name: "Portobello Sandwich", calories_per_100g: 156, source: "recipe")

    get repeats_path(q: "porto")

    assert_select "li", text: /recipe/i
    assert_select "li", text: /eaten/i
  end

  # 190 of 224 foods were imported from the household's recipes and every one of them
  # said "entered by hand", which was true of none.
  test "an imported recipe does not claim somebody typed it" do
    Food.create!(name: "Portobello Sandwich", calories_per_100g: 156, source: "recipe")

    get repeats_path(q: "portobello")

    assert_match(/from your recipes/, response.body)
    assert_no_match(/entered by hand/, response.body)
  end

  private
    # Which of the candidate names the page prints first.
    def first_named(pattern)
      response.body.scan(pattern).first
    end

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
