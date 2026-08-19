require "test_helper"

class Ai::MealToolsTest < ActiveSupport::TestCase
  test "every tool is a well-formed schema the dispatcher knows about" do
    Ai::MealTools::ALL.each do |tool|
      assert tool[:name].present?
      assert tool[:description].present?
      assert_equal "object", tool.dig(:input_schema, :type)

      properties = tool.dig(:input_schema, :properties).keys.map(&:to_s)
      assert_equal [], tool.dig(:input_schema, :required) - properties,
        "#{tool[:name]} requires a property it doesn't define"
    end
  end

  test "the tool names match the dispatcher's cases" do
    assert_equal %w[ log_meal update_meal copy_to_household_member log_exercise ],
      Ai::MealTools::ALL.map { |tool| tool[:name] }
  end

  test "log_meal's writable properties are all whitelisted or handled by name" do
    handled = Ai::ToolHandlers::MEAL_ATTRS + %w[ food_name ]
    properties = Ai::MealTools::LOG_MEAL.dig(:input_schema, :properties).keys.map(&:to_s)

    assert_equal [], properties - handled,
      "a schema property the handler drops on the floor is a silently ignored correction"
  end

  test "update_meal's writable properties are all whitelisted or handled by name" do
    handled = Ai::ToolHandlers::MEAL_ATTRS + %w[ food_name meal_entry_id ]
    properties = Ai::MealTools::UPDATE_MEAL.dig(:input_schema, :properties).keys.map(&:to_s)

    assert_equal [], properties - handled
  end

  test "the schemas are frozen, because they are part of the cached prefix" do
    assert Ai::MealTools::ALL.frozen?
    assert Ai::MealTools::LOG_MEAL.frozen?
  end
end
