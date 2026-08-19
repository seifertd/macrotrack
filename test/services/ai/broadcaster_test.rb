require "test_helper"
require "turbo/broadcastable/test_helper"

class Ai::BroadcasterTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @user = users(:doug)
    @conversation = @user.conversation!
  end

  # The partials rendered here run outside a request — no Current.user, no controller.
  # That is a different code path from the one the controller tests cover, and the
  # failure mode is a job that dies mid-turn after the meal is already in the database.
  test "an assistant turn renders into the stream" do
    message = @conversation.messages.create!(
      role: "assistant", content: [ { "type" => "text", "text" => "Logged — 520 kcal." } ]
    )

    assert_turbo_stream_broadcasts @conversation, count: 1 do
      Ai::Broadcaster.append_message(message)
    end
  end

  test "a confirmation card renders from a tool result, outside any request" do
    entry = @user.meal_entries.create!(
      source: "text", consumed_at: Time.current, calories: 520, confidence: "low",
      food: Food.find_or_create_by_name("bowl of chili")
    )
    message = @conversation.messages.create!(role: "user", content: [ {
      "type" => "tool_result", "tool_use_id" => "toolu_1",
      "content" => { logged: true, meal_entry_id: entry.id }.to_json
    } ])

    payloads = capture_turbo_stream_broadcasts(@conversation) do
      Ai::Broadcaster.append_message(message)
    end

    assert_match(/bowl of chili/, payloads.join)
  end

  test "a tool-only assistant turn broadcasts nothing" do
    message = @conversation.messages.create!(
      role: "assistant",
      content: [ { "type" => "tool_use", "id" => "toolu_1", "name" => "log_meal", "input" => {} } ]
    )

    assert_no_turbo_stream_broadcasts @conversation do
      Ai::Broadcaster.append_message(message)
    end
  end

  test "the header totals re-render for the day the user is actually in" do
    Ai::Broadcaster.refresh_totals(@user)
    stream = broadcasts(stream_name_from(@conversation)).map { |raw| JSON.parse(raw) }.join

    # Asserted against the raw payload rather than the rendered fragment, because the
    # target is the half that fails silently: a replace aimed at an id that isn't on
    # the page does nothing at all, and looks exactly like a working broadcast here.
    assert_match(/action="replace" target="header_strip"/, stream)
    assert_match(/2,000 kcal/, stream)
  end
end
