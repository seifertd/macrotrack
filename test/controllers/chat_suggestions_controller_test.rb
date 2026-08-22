require "test_helper"

class ChatSuggestionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @doug = users(:doug)
    @partner = users(:partner)
    sign_in_as @doug
    @source = @partner.meal_entries.create!(
      source: "text", consumed_at: 2.hours.ago, quantity_grams: 360, calories: 559,
      protein_g: 30, fat_g: 20, carbs_g: 50, meal_type: "dinner",
      food: Food.find_or_create_by_name("Burst Cherry Tomato Pasta")
    )
  end

  test "accepting logs the meal without calling the model at all" do
    suggestion = offer

    assert_no_enqueued_jobs only: AiChatTurnJob do
      assert_difference -> { @doug.meal_entries.count }, 1 do
        post accept_chat_suggestion_path(suggestion), as: :turbo_stream
      end
    end

    entry = @doug.meal_entries.order(:id).last
    assert_equal "matched", entry.source, "§7 path 1, not a household copy"
    assert_equal 559.0, entry.calories.to_f
    assert_equal @source.food_id, entry.food_id, "the same food row, so it doesn't fork into a duplicate"
    assert_response :success
  end

  test "accepting retires the buttons but keeps what was offered in the transcript" do
    suggestion = offer

    post accept_chat_suggestion_path(suggestion), as: :turbo_stream

    assert_not suggestion.reload.suggestion?
    assert_match(/Same again\?/, suggestion.text)
    assert_match(/turbo-stream action="remove"/, response.body)
    assert_match(/turbo-stream action="replace" target="header_strip"/, response.body)
  end

  test "declining hands the turn to the model and logs nothing" do
    suggestion = offer

    assert_enqueued_with job: AiChatTurnJob, args: [ @doug.conversation!, { retrieval: false } ] do
      assert_no_difference -> { @doug.meal_entries.count } do
        post decline_chat_suggestion_path(suggestion), as: :turbo_stream
      end
    end

    assert_not suggestion.reload.suggestion?
  end

  test "declining records the refusal as a turn of its own, and renders it" do
    suggestion = offer

    post decline_chat_suggestion_path(suggestion), as: :turbo_stream

    reply = @doug.conversation!.messages.last

    assert_equal "user", reply.role
    assert_equal ChatSuggestionsController::REFUSAL, reply.text
    assert_nil reply.input_source, "nobody typed it — it must not become an entry's raw_input"
    assert_match(/turbo-stream action="append" target="messages"/, response.body)
    assert_match ChatSuggestionsController::REFUSAL, response.body
  end

  test "the request that follows a decline is a legal one, and actually gets answered" do
    say "a single burst cherry tomato pasta"
    suggestion = offer

    post decline_chat_suggestion_path(suggestion), as: :turbo_stream
    client = with_fake_client(Ai::FakeClient.text("Roughly 180 kcal for one.")) { perform_enqueued_jobs }

    # The bug this pins: the transcript ended on the offer, so the request was a prefill —
    # a 400 on every current model — and the matcher choked on the "?" in "Same again?"
    # before it even got that far. Either way the user pressed the button and nothing came.
    assert_equal "user", client.last_request[:messages].last[:role]
    assert_equal "Roughly 180 kcal for one.", @doug.conversation!.messages.last.text
  end

  test "the turn after a decline is not handed the hints it just refused" do
    say "a single burst cherry tomato pasta"

    post decline_chat_suggestion_path(offer), as: :turbo_stream
    client = with_fake_client(Ai::FakeClient.text("ok")) { perform_enqueued_jobs }

    volatile = client.last_request[:system_].last[:text]

    assert_no_match(/Burst Cherry Tomato Pasta/, volatile,
      "the hints block tells the model to prefer a stored entry over estimating")
  end

  test "a suggestion cannot be answered twice" do
    suggestion = offer
    post accept_chat_suggestion_path(suggestion), as: :turbo_stream

    assert_no_difference -> { @doug.meal_entries.count } do
      post accept_chat_suggestion_path(suggestion), as: :turbo_stream
    end

    assert_response :not_found
  end

  test "cannot answer somebody else's suggestion" do
    theirs = @partner.conversation!.messages.create!(
      role: "assistant", suggested_meal_entry: @source,
      content: [ { "type" => "text", "text" => "Same again?" } ]
    )

    assert_no_difference -> { @doug.meal_entries.count } do
      post accept_chat_suggestion_path(theirs), as: :turbo_stream
    end

    assert_response :not_found
  end

  test "requires a signed-in user" do
    suggestion = offer
    sign_out

    post accept_chat_suggestion_path(suggestion)

    assert_redirected_to new_session_path
  end

  private
    def say(text)
      @doug.conversation!.messages.create!(
        role: "user", input_source: "text",
        content: [ { "type" => "text", "text" => text } ]
      )
    end

    def offer
      @doug.conversation!.messages.create!(
        role: "assistant", suggested_meal_entry: @source,
        content: [ { "type" => "text", "text" => "Partner had Burst Cherry Tomato Pasta — 559 kcal. Same again?" } ]
      )
    end
end
