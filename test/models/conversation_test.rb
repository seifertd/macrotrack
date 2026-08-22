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

  test "a turn in flight is one the user has spoken for and the model has not answered" do
    assert_not @conversation.awaiting_reply?, "an empty thread is not waiting on anything"

    say "two eggs and toast"
    assert @conversation.awaiting_reply?

    assistant [ { "type" => "text", "text" => "Logged." } ]
    assert_not @conversation.awaiting_reply?
  end

  test "a turn that has been in flight for two minutes has failed, not stalled" do
    say "two eggs and toast"
    @conversation.messages.last.update!(created_at: 3.minutes.ago)

    assert_not @conversation.awaiting_reply?, "an indicator that never stops is worse than one that never starts"
  end

  test "last_input_source defaults to text and survives tool result turns" do
    assert_equal "text", @conversation.last_input_source

    say "dictated this", input_source: "voice"
    tool_results "toolu_1"

    assert_equal "voice", @conversation.last_input_source
  end

  # The controller path is covered in meal_entries_controller_test; this covers all the
  # others. `delete` skips every Rails callback, so the only thing that can prevent a
  # foreign key violation here is the key itself being declared ON DELETE SET NULL — and
  # a rake task, a console session or a cascade all take this path rather than that one.
  test "the pointer at the last logged entry is let go of by the database, not only the model" do
    entry = @conversation.user.meal_entries.create!(
      source: "voice", calories: 100, consumed_at: 1.hour.ago
    )
    @conversation.update!(last_meal_entry: entry)

    assert_nothing_raised { entry.delete }
    assert_nil @conversation.reload.last_meal_entry_id
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
