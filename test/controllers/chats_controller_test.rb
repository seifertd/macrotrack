require "test_helper"

class ChatsControllerTest < ActionDispatch::IntegrationTest
  setup { sign_in_as users(:doug) }

  test "requires a signed-in user" do
    sign_out
    get chat_path

    assert_redirected_to new_session_path
  end

  test "creates the thread on first visit and renders the composer" do
    assert_difference -> { Conversation.count }, 1 do
      get chat_path
    end

    assert_response :success
    assert_select "#composer form[action=?]", chat_messages_path
    assert_select "#messages"
  end

  # Without this the app keeps running the JavaScript it booted with until someone
  # reloads by hand, because nothing importmap_tags renders is tracked and Turbo swapping
  # a body never re-imports a module.
  test "a javascript deploy is something Turbo can notice" do
    get chat_path

    assert_select "meta[name=?][data-turbo-track=?]", "importmap-digest", "reload" do |tags|
      assert_equal Rails.application.importmap.digest(resolver: ApplicationController.helpers),
        tags.first["content"]
    end
  end

  test "the composer can record as well as type, and they are separate forms" do
    get chat_path

    # A form cannot nest and a text field cannot carry a wav, so the mic posts its own.
    assert_select "#composer form[action=?][enctype=?]", voice_entries_path, "multipart/form-data" do
      assert_select "input[type=file][name=?]", "voice_entry[audio]"
      assert_select "button[data-action=?]", "dictation#toggle"
    end
    assert_select "#composer [data-dictation-target=?]", "overlay"
    assert_select "#composer button[data-action=?]", "dictation#finish"
  end

  # The indicator is normally switched on by the broadcast the job sends. Arrive after
  # that broadcast — a reload, or the redirect from the Add screen's "Speak it" — and
  # there is nothing left to receive, so the page has to work it out for itself.
  test "a turn already in flight shows as thinking on a fresh page load" do
    users(:doug).conversation!.messages.create!(
      role: "user", input_source: "voice",
      content: [ { "type" => "text", "text" => "two ikea meatballs" } ]
    )

    get chat_path

    assert_select "#typing_indicator:not(.hidden)"
  end

  test "renders the transcript, its confirmation cards, and skips tool-only turns" do
    conversation = users(:doug).conversation!
    entry = users(:doug).meal_entries.create!(
      source: "text", consumed_at: Time.current, calories: 520, quantity_grams: 400,
      confidence: "medium", assumptions: "Assumed a pub-sized bowl.",
      food: Food.find_or_create_by_name("bowl of chili")
    )

    conversation.messages.create!(role: "user", input_source: "text",
      content: [ { "type" => "text", "text" => "a bowl of chili" } ])
    conversation.messages.create!(role: "assistant",
      content: [ { "type" => "tool_use", "id" => "toolu_1", "name" => "log_meal", "input" => {} } ])
    conversation.messages.create!(role: "user", content: [ {
      "type" => "tool_result", "tool_use_id" => "toolu_1",
      "content" => { logged: true, meal_entry_id: entry.id }.to_json
    } ])
    conversation.messages.create!(role: "assistant",
      content: [ { "type" => "text", "text" => "Logged — 520 kcal." } ])

    get chat_path

    assert_response :success
    assert_select "#messages > div", 3, "the tool-only assistant turn has nothing to render"
    assert_select "body", text: /a bowl of chili/
    assert_select "body", text: /Logged — 520 kcal\./
    assert_select "body", text: /Assumed a pub-sized bowl\./
  end

  test "a failed tool result renders nothing rather than leaking an exception" do
    conversation = users(:doug).conversation!
    conversation.messages.create!(role: "user", content: [ {
      "type" => "tool_result", "tool_use_id" => "toolu_1",
      "content" => "Couldn't find that entry", "is_error" => true
    } ])

    get chat_path

    assert_response :success
    assert_select "body", { text: /Couldn't find that entry/, count: 0 }
  end
end
