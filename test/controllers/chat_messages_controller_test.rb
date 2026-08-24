require "test_helper"

class ChatMessagesControllerTest < ActionDispatch::IntegrationTest
  setup do
    Rails.cache.clear   # the rate-limit counter lives here and outlives an example
    sign_in_as users(:doug)
  end

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
  # Each typed turn is up to five claude-opus-5 calls, and nothing coalesces a resubmit.
  test "a burst past the limit is refused rather than billed" do
    limit = 20

    limit.times { |n| post chat_messages_path, params: { chat_message: { text: "meal #{n}" } }, as: :turbo_stream }
    assert_response :success, "the limit itself must not bite a real conversation"

    assert_no_difference -> { Message.count } do
      assert_no_enqueued_jobs only: AiChatTurnJob do
        post chat_messages_path, params: { chat_message: { text: "one too many" } }, as: :turbo_stream
      end
    end

    assert_response :too_many_requests
  end

  # A composer that never comes back reads as the app having died rather than said no.
  test "a refused turn still says so and hands the composer back" do
    21.times { post chat_messages_path, params: { chat_message: { text: "x" } }, as: :turbo_stream }

    assert_response :too_many_requests
    assert_match(/turbo-stream action="append" target="messages"/, response.body)
    assert_match(/turbo-stream action="replace" target="composer"/, response.body)
    assert_match(/Give it a moment/, response.body)
  end

  # Both accounts sit behind one household NAT, so the default IP key would let one
  # person's stuck client lock the other out of their own tracker.
  test "the limit is per person, not per address" do
    21.times { post chat_messages_path, params: { chat_message: { text: "x" } }, as: :turbo_stream }
    assert_response :too_many_requests

    sign_in_as users(:partner)
    post chat_messages_path, params: { chat_message: { text: "my own first turn" } }, as: :turbo_stream

    assert_response :success
  end
end
