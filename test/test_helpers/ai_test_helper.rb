module AiTestHelper
  # Every test in the suite runs through this: the real client is never constructed,
  # so a missing API key can't turn into a network call by accident.
  def with_fake_client(*responses)
    client = Ai::FakeClient.new(*responses)
    Ai.with_client(client) { yield client }
    client
  end

  def tool_use_block(name, input, id: "toolu_1")
    Anthropic::ToolUseBlock.new(id: id, caller_: { type: :direct }, input: input, name: name)
  end
end
