# Answering a retrieval suggestion. "Yes" logs the meal with no model call at all,
# which is the whole point of §7 path 1; "no" hands the turn to the model as usual.
class ChatSuggestionsController < ApplicationController
  before_action :set_message

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
    AiChatTurnJob.perform_later(@message.conversation)

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
