# Design §16. The Ruby SDK's tool_runner would drive this loop, but the manual form is
# what lets us persist each turn and broadcast between iterations.
#
# One deviation from §16: the user's message is created by the controller, not here, so
# it renders the instant it is submitted rather than after the job picks up. The job
# owns everything from the first API call onward.
class AiChatTurnJob < ApplicationJob
  MAX_ITERATIONS = 5

  # No retry_on: the SDK already retries 429s and 5xxs twice on its own, and a job
  # retry would replay a whole turn's worth of tokens to recover a failure the user
  # can fix by pressing send again.

  def perform(conversation)
    user = conversation.user
    client = Ai.client

    Ai::Broadcaster.thinking(conversation, on: true)

    # Built once, not per iteration. Regenerating it mid-turn re-reads the day totals
    # *after* this turn's own tool calls have already changed them, so the block's own
    # "at the start of this turn" label stops being true and the model ends up narrating
    # a day total that double-counts the meal it just logged. Holding it still also keeps
    # the cached prefix identical across the turn's requests, which is the point of §8.
    system_prompt = Ai::Prompts.meal_logging(user)

    MAX_ITERATIONS.times do
      response = client.messages.create(
        model: Rails.configuration.x.ai_model,
        max_tokens: Rails.configuration.x.ai_max_tokens,   # thinking + text share this — §8
        thinking: { type: "adaptive" },                    # never disable — §8's silent-failure trap
        output_config: { effort: Rails.configuration.x.ai_effort },
        system_: system_prompt,
        messages: conversation.to_api_messages,            # windowed — §9
        tools: Ai::MealTools::ALL
      )

      log_usage(response.usage)
      record(conversation, role: "assistant", content: blocks(response.content), usage: response.usage)

      break unless response.stop_reason == :tool_use

      # Execute every tool_use block and return ALL results in ONE user message.
      # Splitting them across messages teaches the model to stop calling tools in
      # parallel, and nothing in the response would tell you that had happened.
      results = response.content.filter_map do |block|
        next unless block.type == :tool_use

        Ai::ToolHandlers.dispatch(user: user, conversation: conversation, tool_use: block)
      end

      record(conversation, role: "user", content: results.map(&:deep_stringify_keys))
      Ai::Broadcaster.refresh_totals(user)
    end
  rescue Anthropic::Errors::AuthenticationError, Anthropic::Errors::PermissionDeniedError => e
    # Worth its own branch: a 401 here means no usable credential was found, which is a
    # setup problem no amount of pressing send again will fix.
    Rails.logger.error("chat turn unauthorized: #{e.class}: #{e.message}")
    Ai::Broadcaster.failed(conversation, "No usable Anthropic API key — check credentials.anthropic.api_key.")
    raise
  rescue Anthropic::Errors::APIError => e
    Rails.logger.error("chat turn failed: #{e.class}: #{e.message}")
    Ai::Broadcaster.failed(conversation, "Couldn't reach the model just then. Try that again?")
    raise
  ensure
    Ai::Broadcaster.thinking(conversation, on: false)
  end

  private
    def record(conversation, role:, content:, usage: nil)
      message = conversation.messages.create!(
        role: role, content: content, token_estimate: token_estimate(usage)
      )
      Ai::Broadcaster.append_message(message)
      message
    end

    # Blocks go in exactly as they came out, including thinking blocks whose text is
    # empty — their signature only validates if the block round-trips untouched.
    #
    # Serialized one block at a time, and that is load-bearing. `content.to_json` on the
    # array goes through ActiveSupport's as_json, which reads each block's *internal*
    # field names — so a tool_use block comes out carrying `caller_` instead of `caller`
    # and the next request is a 400. Only the SDK's own per-object to_json maps fields
    # back to their API names.
    def blocks(content)
      content.map { |block| JSON.parse(block.to_json) }
    end

    # cache_read is the number that tells you whether the breakpoint still works. It has
    # no failure mode you can see from the outside — a dead cache just costs more — so it
    # goes in the log where a bad deploy can be spotted rather than inferred from a bill.
    def log_usage(usage)
      Rails.logger.info(
        "ai turn: in=#{usage.input_tokens} out=#{usage.output_tokens} " \
        "cache_write=#{usage.cache_creation_input_tokens} cache_read=#{usage.cache_read_input_tokens}"
      )
    end

    # Logged from day one so a runaway loop shows up as a cost, not a surprise (§14.3).
    def token_estimate(usage)
      return nil if usage.nil?

      usage.input_tokens.to_i + usage.output_tokens.to_i
    end
end
