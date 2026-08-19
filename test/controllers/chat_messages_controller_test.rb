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
