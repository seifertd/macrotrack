# Design §7 path 1: before anything is estimated, check whether this household has eaten
# it before. Shared by the typed and the dictated entry points, because a meal that has
# been eaten before is no less so for having been spoken.
module OffersRetrieval
  extend ActiveSupport::Concern

  private
    def offer_retrieval(conversation, text)
      match = Meals::Matcher.new(Current.user, text).best_entry
      log_retrieval(text, match)
      return nil unless match

      conversation.messages.create!(
        role: "assistant", suggested_meal_entry: match.entry,
        content: [ { "type" => "text", "text" => helpers.suggestion_text(match, Current.user) } ]
      )
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
