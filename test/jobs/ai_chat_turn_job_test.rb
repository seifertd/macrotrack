require "test_helper"

class AiChatTurnJobTest < ActiveJob::TestCase
  setup do
    @user = users(:doug)
    @conversation = @user.conversation!
    @conversation.messages.create!(
      role: "user", input_source: "text",
      content: [ { "type" => "text", "text" => "a bowl of chili" } ]
    )
  end

  test "a plain text reply is persisted and ends the turn in one call" do
    client = run_turn(Ai::FakeClient.text("How big a bowl?"))

    assert_equal 1, client.requests.length
    assert_equal "How big a bowl?", @conversation.messages.last.text
    assert_equal "assistant", @conversation.messages.last.role
  end

  test "a tool call is executed and answered, then the model gets a second turn" do
    client = run_turn(
      Ai::FakeClient.tool_use({ name: "log_meal", input: meal_input }, text: "Logging that."),
      Ai::FakeClient.text("Logged — 520 kcal.")
    )

    assert_equal 2, client.requests.length
    assert_equal 1, @user.meal_entries.where(source: "text").count
    assert_equal "Logged — 520 kcal.", @conversation.messages.last.text
  end

  test "two tool calls in one turn come back in a single user message" do
    run_turn(
      Ai::FakeClient.tool_use(
        { id: "toolu_a", name: "log_meal", input: meal_input },
        { id: "toolu_b", name: "log_meal", input: meal_input.merge("food_name" => "sourdough slice") }
      ),
      Ai::FakeClient.text("Both logged.")
    )

    results = @conversation.messages.select(&:tool_result?)

    assert_equal 1, results.length, "splitting results across messages teaches the model to stop parallelising"
    assert_equal 2, results.first.content.length
    assert_equal %w[ toolu_a toolu_b ], results.first.content.map { |b| b["tool_use_id"] }
  end

  test "the assistant turn is replayed verbatim on the next request" do
    run_turn(
      Ai::FakeClient.tool_use({ name: "log_meal", input: meal_input }),
      Ai::FakeClient.text("Done.")
    )

    stored = @conversation.messages.find { |m| m.role == "assistant" }.content.first

    assert_equal "tool_use", stored["type"]
    assert_equal "log_meal", stored["name"]
  end

  test "a correction updates the same entry rather than creating a second one" do
    run_turn(
      Ai::FakeClient.tool_use({ name: "log_meal", input: meal_input }),
      Ai::FakeClient.text("Logged.")
    )
    entry = @user.meal_entries.order(:id).last

    @conversation.messages.create!(
      role: "user", input_source: "text",
      content: [ { "type" => "text", "text" => "make that double chicken" } ]
    )

    assert_no_difference -> { @user.meal_entries.count } do
      run_turn(
        Ai::FakeClient.tool_use({ id: "toolu_x", name: "update_meal", input: {
          "meal_entry_id" => entry.id, "calories" => 780,
          "protein_g" => 60, "fat_g" => 30, "carbs_g" => 45
        } }),
        Ai::FakeClient.text("Updated to 780.")
      )
    end

    assert_equal 780, entry.reload.calories
  end

  test "persisted blocks use the API's field names, not the SDK's internal ones" do
    run_turn(
      Ai::FakeClient.tool_use({ name: "log_meal", input: meal_input }),
      Ai::FakeClient.text("Done.")
    )

    stored = @conversation.messages.find { |m| m.role == "assistant" }.content.first

    # The SDK calls this field `caller_` internally and `caller` on the wire. Anything
    # that serializes a block by its internal names — ActiveSupport's as_json, say —
    # produces history the API rejects with a 400 on the *next* request, which is a
    # long way from where the mistake was made.
    assert_equal({ "type" => "direct" }, stored["caller"])
    assert_empty stored.keys.grep(/_\z/), "internal field names must not reach the wire"
  end

  test "the stored history is accepted by the SDK's own request builder" do
    run_turn(
      Ai::FakeClient.tool_use({ name: "log_meal", input: meal_input }),
      Ai::FakeClient.text("Done.")
    )

    body, = Anthropic::MessageCreateParams.dump_request(
      model: "claude-opus-5", max_tokens: 8192,
      messages: @conversation.to_api_messages, tools: Ai::MealTools::ALL
    )
    replayed = body[:messages].flat_map { |m| Array(m[:content]) }
    tool_use = replayed.find { |block| block[:type] == "tool_use" || block["type"] == "tool_use" }

    assert tool_use, "the tool_use block must survive the round trip"
    assert_empty tool_use.keys.map(&:to_s).grep(/_\z/)
  end

  test "the request carries adaptive thinking, low effort, and the tool schemas" do
    client = run_turn(Ai::FakeClient.text("ok"))
    request = client.last_request

    assert_equal "claude-opus-5", request[:model]
    assert_equal({ type: "adaptive" }, request[:thinking])
    assert_equal({ effort: "low" }, request[:output_config])
    assert_equal 8192, request[:max_tokens]
    assert_equal Ai::MealTools::ALL, request[:tools]
  end

  test "the cache breakpoint sits on the last static system block" do
    client = run_turn(Ai::FakeClient.text("ok"))
    system = client.last_request[:system_]

    assert_equal 2, system.length
    assert_equal({ type: "ephemeral" }, system.first[:cache_control])
    assert_nil system.last[:cache_control], "the volatile block must sit below the breakpoint"
    assert_match(/Day totals at the start of this turn/, system.last[:text])
  end

  test "usage is recorded so a runaway loop shows up as a number" do
    run_turn(Ai::FakeClient.text("ok"))

    assert_equal 150, @conversation.messages.last.token_estimate
  end

  test "the loop is bounded even if the model never stops calling tools" do
    responses = Array.new(AiChatTurnJob::MAX_ITERATIONS + 3) do
      Ai::FakeClient.tool_use({ name: "log_meal", input: meal_input })
    end

    client = run_turn(*responses)

    assert_equal AiChatTurnJob::MAX_ITERATIONS, client.requests.length
  end

  private
    def meal_input
      {
        "food_name" => "bowl of chili", "quantity_grams" => 400, "calories" => 520,
        "protein_g" => 32, "fat_g" => 24, "carbs_g" => 38,
        "meal_type" => "dinner", "confidence" => "medium"
      }
    end

    def run_turn(*responses)
      with_fake_client(*responses) do |client|
        AiChatTurnJob.perform_now(@conversation)
        return client
      end
    end
end
