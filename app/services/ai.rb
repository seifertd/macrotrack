# The seam between the app and Anthropic. Everything that talks to the API goes
# through `Ai.client`, which is swappable — the test suite points it at
# Ai::FakeClient and never opens a socket.
module Ai
  class << self
    attr_writer :client

    def client
      @client ||= build_client
    end

    def reset_client!
      @client = nil
    end

    # Swap the client for the duration of a block, then put the real one back.
    def with_client(replacement)
      previous = @client
      @client = replacement
      yield
    ensure
      @client = previous
    end

    private
      # Credentials are where the plan says the key lives, so a configured key wins.
      # With none, hand the SDK an empty constructor rather than raising: it resolves
      # ANTHROPIC_API_KEY, ANTHROPIC_AUTH_TOKEN, an OAuth profile from `ant auth login`,
      # and workload identity on its own. Reimplementing that chain here would only
      # mean getting it wrong later, and a key that works everywhere else in the toolkit
      # should work here too. A setup with nothing at all fails as a 401 on first use,
      # which AiChatTurnJob reports as a missing key rather than a network blip.
      def build_client
        key = configured_api_key

        key ? Anthropic::Client.new(api_key: key) : Anthropic::Client.new
      end

      def configured_api_key
        Rails.application.credentials.dig(:anthropic, :api_key).presence
      end
  end
end
