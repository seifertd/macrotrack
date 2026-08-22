require "test_helper"

class ChatMessagesControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:doug) }

  test "stores the typed turn and enqueues the model call" do
    assert_difference -> { Message.count }, 1 do
      assert_enqueued_with job: AiChatTurnJob do
        post chat_messages_path, params: { chat_message: { text: "a bowl of chili" } },
          as: :turbo_stream
      end
    end

    assert_response :success

    message = Message.order(:created_at).last
    assert_equal "user", message.role
    assert_equal "text", message.input_source
    assert_equal "a bowl of chili", message.text
  end

  test "the turbo stream appends the message, shows the indicator, and clears the field" do
    post chat_messages_path, params: { chat_message: { text: "two eggs" } }, as: :turbo_stream

    assert_match(/turbo-stream action="append" target="messages"/, response.body)
    assert_match(/turbo-stream action="replace" target="typing_indicator"/, response.body)
    assert_match(/turbo-stream action="replace" target="composer"/, response.body)
    assert_no_match(/value="two eggs"/, response.body)
  end

  # Design §7: retrieval is path 1 and inference is path 3. A meal the household has
  # eaten before should never reach the model.
  test "a meal we have eaten before is offered instead of parsed" do
    source = users(:partner).meal_entries.create!(
      source: "text", consumed_at: 2.hours.ago, quantity_grams: 360, calories: 559,
      protein_g: 30, fat_g: 20, carbs_g: 50,
      food: Food.find_or_create_by_name("Burst Cherry Tomato Pasta")
    )

    assert_no_enqueued_jobs only: AiChatTurnJob do
      post chat_messages_path, params: { chat_message: { text: "the burst cherry tomato pasta again" } },
        as: :turbo_stream
    end

    suggestion = Message.order(:created_at).last
    assert_equal "assistant", suggestion.role
    assert_equal source, suggestion.suggested_meal_entry
    assert_match(/Partner had Burst Cherry Tomato Pasta/, suggestion.text)
    assert_match(/559 kcal for 360g/, suggestion.text)
    assert_no_match(/typing_indicator/, response.body, "nothing is thinking — retrieval already answered")
  end

  test "something new still goes to the model" do
    users(:partner).meal_entries.create!(
      source: "text", consumed_at: 2.hours.ago, quantity_grams: 360, calories: 559,
      food: Food.find_or_create_by_name("Burst Cherry Tomato Pasta")
    )

    assert_enqueued_with job: AiChatTurnJob do
      post chat_messages_path, params: { chat_message: { text: "grilled salmon and rice" } },
        as: :turbo_stream
    end

    assert_nil Message.order(:created_at).last.suggested_meal_entry
    assert_match(/turbo-stream action="replace" target="typing_indicator"/, response.body)
  end

  test "an empty message is not a turn" do
    assert_no_difference -> { Message.count } do
      assert_no_enqueued_jobs only: AiChatTurnJob do
        post chat_messages_path, params: { chat_message: { text: "   " } }, as: :turbo_stream
      end
    end
  end

  test "requires a signed-in user" do
    sign_out

    assert_no_difference -> { Message.count } do
      post chat_messages_path, params: { chat_message: { text: "a bowl of chili" } }
    end
    assert_redirected_to new_session_path
  end
end
