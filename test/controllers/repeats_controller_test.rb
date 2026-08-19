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

  test "the portion screen offers both people and defaults to the source portion" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559)

    get repeat_path(source)

    assert_response :success
    assert_select "input[name=grams][value=?]", "360"
    assert_select "button[name=target_id][value=?]", @doug.id.to_s, text: "For me"
    assert_select "button[name=target_id][value=?]", @partner.id.to_s, text: "For Partner"
  end

  test "an unweighed source offers multipliers instead of a grams field" do
    source = log(@partner, "their dinner", quantity_grams: nil, calories: 500)

    get repeat_path(source)

    assert_select "input[name=grams]", count: 0
    assert_select "input[name=multiplier]", count: 1
  end

  test "logging a half portion to myself writes a scaled copy" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559, protein_g: 30)

    assert_difference -> { @doug.meal_entries.count }, 1 do
      post log_repeat_path(source), params: { grams: 180, target_id: @doug.id }
    end

    entry = @doug.meal_entries.order(:id).last
    assert_equal 279.5, entry.calories.to_f
    assert_equal 15.0, entry.protein_g.to_f
    assert_equal "copied", entry.source
    assert_redirected_to day_path(@doug.local_today)
  end

  test "logging for the other person writes to their day, not mine" do
    source = log(@doug, "my dinner", quantity_grams: 400, calories: 800)

    assert_difference -> { @partner.meal_entries.count }, 1 do
      assert_no_difference -> { @doug.meal_entries.count } do
        post log_repeat_path(source), params: { grams: 200, target_id: @partner.id }
      end
    end

    assert_equal 400.0, @partner.meal_entries.order(:id).last.calories.to_f
  end

  test "cannot log into somebody outside the household" do
    source = log(@doug, "my dinner", quantity_grams: 400, calories: 800)

    assert_no_difference -> { users(:neighbor).meal_entries.count } do
      post log_repeat_path(source), params: { grams: 200, target_id: users(:neighbor).id }
    end

    assert_response :not_found
  end

  test "no target means me, so a stray submit cannot land on the wrong day" do
    source = log(@partner, "their dinner", quantity_grams: 360, calories: 559)

    assert_difference -> { @doug.meal_entries.count }, 1 do
      post log_repeat_path(source), params: { grams: 180 }
    end
  end

  private
    def log(user, name, food: nil, consumed_at: 1.hour.ago, quantity_grams: 300, **attributes)
      user.meal_entries.create!({
        source: "manual", consumed_at: consumed_at, quantity_grams: quantity_grams,
        calories: 500, protein_g: 20, fat_g: 15, carbs_g: 40,
        food: food || Food.find_or_create_by_name(name)
      }.merge(attributes))
    end
end
