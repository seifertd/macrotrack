module Ai
  # A stand-in for Anthropic::Client that returns canned responses and records what it
  # was asked. It builds real Anthropic::Message objects rather than stubs, so the job
  # exercises the same block types, symbol enums, and serialization as production —
  # a fake that returned plain hashes would hide exactly the bugs worth catching.
  class FakeClient
    attr_reader :requests

    def initialize(*responses)
      @responses = responses.flatten
      @requests = []
    end

    def messages
      Endpoint.new(self)
    end

    def next_response(params)
      @requests << params
      @responses.shift || self.class.text("(fake client ran out of responses)")
    end

    def last_request
      requests.last
    end

    class Endpoint
      def initialize(client)
        @client = client
      end

      def create(**params)
        @client.next_response(params)
      end
    end

    class << self
      def text(text)
        message([ { type: :text, text: text, citations: nil } ], stop_reason: :end_turn)
      end

      # Several tool_use blocks in one response is the case worth pinning down: every
      # result has to come back in a *single* user message, and nothing about a passing
      # single-tool test tells you whether that holds.
      def tool_use(*calls, text: nil)
        blocks = []
        blocks << { type: :text, text: text, citations: nil } if text
        calls.flatten.each_with_index do |call, index|
          blocks << {
            type: :tool_use,
            id: call[:id] || "toolu_#{index}",
            name: call.fetch(:name),
            input: call.fetch(:input),
            caller: { type: :direct }
          }
        end

        message(blocks, stop_reason: :tool_use)
      end

      # Built through the same coercion the real client runs on an HTTP response body,
      # not through Anthropic::Message.new. The difference is not cosmetic: `.new` files
      # unrecognised keys away verbatim, so a hand-built block serializes differently
      # from a parsed one, and a fake that gets that wrong will happily green-light a
      # request the API rejects. This path is the one that shipped a `caller_` to
      # production once already.
      def message(content, stop_reason:, usage: nil)
        Anthropic::Internal::Type::Converter.coerce(Anthropic::Message, {
          id: "msg_fake",
          container: nil,
          model: "claude-opus-5",
          role: :assistant,
          stop_details: nil,
          stop_reason: stop_reason,
          stop_sequence: nil,
          content: content,
          usage: usage || {
            input_tokens: 100, output_tokens: 50,
            cache_creation_input_tokens: 0, cache_read_input_tokens: 0,
            server_tool_use: nil, service_tier: nil
          }
        })
      end
    end
  end
end
