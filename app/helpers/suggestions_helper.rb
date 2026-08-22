module SuggestionsHelper
  # The offer itself, in words. Lives in a helper because it is display: two controllers
  # write it and the model reads it back out of the transcript afterwards.
  def suggestion_text(match, user)
    entry = match.entry
    portion = entry.quantity_grams.present? ? " for #{grams(entry.quantity_grams)}" : ""
    whose = entry.user == user ? "You" : entry.user.name
    when_eaten = user.local_date(entry.consumed_at)

    "#{whose} had #{entry.display_name} on #{when_eaten.strftime('%-d %B')} — " \
      "#{calories(entry.calories)} kcal#{portion}. Same again?"
  end
end
