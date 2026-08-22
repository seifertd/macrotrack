require "test_helper"

class ConversationTest < ActiveSupport::TestCase
  setup do
    @conversation = users(:doug).conversation!
  end

  test "to_api_messages replays stored blocks verbatim, with symbol keys" do
    say "a bowl of chili"
    assistant [ { "type" => "thinking", "thinking" => "", "signature" => "abc" },
                { "type" => "text", "text" => "Logged." } ]

    replayed = @conversation.to_api_messages

    assert_equal [ "user", "assistant" ], replayed.map { |m| m[:role] }
    assert_equal({ type: "thinking", thinking: "", signature: "abc" }, replayed.last[:content].first)
  end

  test "the window never starts on a tool_result whose tool_use has fallen off" do
    # More turns than the window holds, arranged so a naive `last(WINDOW)` would slice
    # the history open right after a tool_use — the shape the API rejects with a 400.
    # Three rows per turn, so that a naive `last(WINDOW)` slices the history open
    # between a tool_use and its tool_result — the shape the API rejects with a 400.
    12.times do |n|
      say "meal #{n}"
      assistant [ { "type" => "tool_use", "id" => "toolu_#{n}", "name" => "log_meal", "input" => {} } ]
      tool_results "toolu_#{n}"
    end

    replayed = @conversation.to_api_messages
    naive = @conversation.messages.last(Conversation::WINDOW)

    assert_equal "tool_use", naive.first.content.first["type"], "the naive slice really is unsafe here"
    assert_equal "user", replayed.first[:role]
    assert_equal "text", replayed.first[:content].first[:type]
    assert_operator replayed.length, :<, Conversation::WINDOW, "the unsafe leading turn must be trimmed"
  end

  test "last_user_text is the transcript, not the tool results that follow it" do
    say "two eggs and toast"
    assistant [ { "type" => "tool_use", "id" => "toolu_1", "name" => "log_meal", "input" => {} } ]
    tool_results "toolu_1"

    assert_equal "two eggs and toast", @conversation.last_user_text
  end

  test "last_user_text is what the user said, not what was offered back to them" do
    say "a single chicken taquito"
    assistant [ { "type" => "text", "text" => "You had them on 21 August — 645 kcal. Same again?" } ]
    # How a declined suggestion is recorded: a user turn nobody typed.
    @conversation.messages.create!(
      role: "user", content: [ { "type" => "text", "text" => "No — not that one." } ]
    )

    assert_equal "a single chicken taquito", @conversation.last_user_text
  end

  test "last_input_source defaults to text and survives tool result turns" do
    assert_equal "text", @conversation.last_input_source

    say "dictated this", input_source: "voice"
    tool_results "toolu_1"

    assert_equal "voice", @conversation.last_input_source
  end

  private
    def say(text, input_source: "text")
      @conversation.messages.create!(
        role: "user", input_source: input_source,
        content: [ { "type" => "text", "text" => text } ]
      )
    end

    def assistant(content)
      @conversation.messages.create!(role: "assistant", content: content)
    end

    def tool_results(tool_use_id)
      @conversation.messages.create!(
        role: "user",
        content: [ { "type" => "tool_result", "tool_use_id" => tool_use_id, "content" => "{}" } ]
      )
    end
end
