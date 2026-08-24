class ChatMessagesController < ApplicationController
  include OffersRetrieval
  include RateLimitsTurns

  # Twenty typed turns a minute is far past meal-logging pace and still well short of what
  # a resubmit loop would spend. See RateLimitsTurns for what each turn actually costs.
  rate_limit_turns to: 20, within: 1.minute

  # The user's message is created here rather than in the job so it renders on the
  # submit, not a second later when a worker picks the job up. Design §16 shows the job
  # doing it; that reads better on the page than it does in practice.
  #
  # Typed turns only. A dictated one arrives at VoiceEntriesController as audio, which is
  # why there is no `input_source` to read off the params here — the composer cannot lie
  # about having been spoken, because it has no way to say it.
  def create
    @conversation = Current.user.conversation!
    text = params.dig(:chat_message, :text).to_s.strip

    if text.blank?
      head :no_content
      return
    end

    @message = @conversation.messages.create!(
      role: "user",
      input_source: "text",
      content: [ { "type" => "text", "text" => text } ]
    )

    # Design §7: retrieval before inference. A meal this household has eaten before is
    # already better data than a fresh estimate, and it costs nothing.
    @suggestion = offer_retrieval(@conversation, text)
    AiChatTurnJob.perform_later(@conversation) unless @suggestion

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path }
    end
  end
end
