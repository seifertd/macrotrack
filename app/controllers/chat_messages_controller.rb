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

    # Design §7: retrieval before inference. A meal this household has eaten before is
    # already better data than a fresh estimate, and it costs nothing.
    @suggestion = suggest(text)
    AiChatTurnJob.perform_later(@conversation) unless @suggestion

    respond_to do |format|
      format.turbo_stream
      format.html { redirect_to chat_path }
    end
  end

  private
    def suggest(text)
      match = Meals::Matcher.new(Current.user, text).best_entry
      log_retrieval(text, match)
      return nil unless match

      @conversation.messages.create!(
        role: "assistant",
        suggested_meal_entry: match.entry,
        content: [ { "type" => "text", "text" => suggestion_text(match) } ]
      )
    end

    def suggestion_text(match)
      entry = match.entry
      portion = entry.quantity_grams.present? ? " for #{helpers.grams(entry.quantity_grams)}" : ""
      whose = entry.user == Current.user ? "You" : entry.user.name
      when_eaten = Current.user.local_date(entry.consumed_at)

      "#{whose} had #{entry.display_name} on #{when_eaten.strftime('%-d %B')} — " \
        "#{helpers.calories(entry.calories)} kcal#{portion}. Same again?"
    end

    # §7 asks for the hit rate to be instrumented, because it is the number that decides
    # whether the pg_trgm-vs-pgvector question in §17 ever needs answering.
    def log_retrieval(text, match)
      Rails.logger.info(
        "meal match: #{match ? 'hit' : 'miss'} score=#{match&.score&.round(2) || '-'} " \
        "name=#{match&.name.inspect} query=#{text.truncate(60).inspect}"
      )
    end
end
