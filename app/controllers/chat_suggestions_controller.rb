# Answering a retrieval suggestion. "Yes" logs the meal with no model call at all,
# which is the whole point of §7 path 1; "no" hands the turn to the model as usual.
class ChatSuggestionsController < ApplicationController
  before_action :set_message

  # Goes into the transcript as the user's own turn. Two things need it: a request whose
  # last message is an assistant turn is a prefill, which the model rejects outright, and
  # the model has no other way to learn the offer was turned down.
  REFUSAL = "No — not that one. Work it out from scratch."

  def accept
    source = @message.suggested_meal_entry
    @entry = MealPortion.new(source).log_for!(Current.user, logged_as: "matched")
    answered!

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to day_path(Current.user.local_today), notice: "Logged." }
    end
  end

  def decline
    answered!
    @reply = @message.conversation.messages.create!(
      role: "user", content: [ { "type" => "text", "text" => REFUSAL } ]
    )
    # No retrieval on the way back: the hints block tells the model to prefer a stored
    # entry over estimating, and the entry it would lead with is the one just refused.
    AiChatTurnJob.perform_later(@message.conversation, retrieval: false)

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path }
    end
  end

  private
    def set_message
      @message = Current.user.conversation!.messages.find(params[:id])
      head :not_found unless @message.suggestion?
    end

    # Clearing the pointer is what retires the buttons. The text of the offer stays in
    # the transcript — it is part of what was said, and the model reads it back.
    def answered!
      @message.update!(suggested_meal_entry: nil)
    end
end
