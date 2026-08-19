module Ai
  # Everything the job pushes to an already-open chat screen. Kept out of the job so
  # the job reads as the API loop it is, and so a test can assert on the loop without
  # a rendering stack in the way.
  module Broadcaster
    def self.append_message(message)
      return unless message.renderable?

      Turbo::StreamsChannel.broadcast_append_to(
        message.conversation,
        target: "messages",
        partial: "messages/message",
        locals: { message: message, user: message.conversation.user }
      )
    end

    def self.thinking(conversation, on:)
      Turbo::StreamsChannel.broadcast_replace_to(
        conversation,
        target: "typing_indicator",
        partial: "chats/typing_indicator",
        locals: { visible: on }
      )
    end

    # The header is the one number both of us actually watch, so it updates the moment
    # a tool writes an entry rather than on the next page load.
    def self.refresh_totals(user)
      Turbo::StreamsChannel.broadcast_replace_to(
        user.conversation!,
        target: "header_strip",
        partial: "shared/header_strip",
        locals: { user: user, date: user.local_today }
      )
    end

    def self.failed(conversation, message)
      Turbo::StreamsChannel.broadcast_append_to(
        conversation,
        target: "messages",
        partial: "chats/failure",
        locals: { message: message }
      )
    end
  end
end
