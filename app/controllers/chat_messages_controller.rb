class ChatMessagesController < ApplicationController
  # The user's message is created here rather than in the job so it renders on the
  # submit, not a second later when a worker picks the job up. Design §16 shows the job
  # doing it; that reads better on the page than it does in practice.
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

    AiChatTurnJob.perform_later(@conversation)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path }
    end
  end
end
