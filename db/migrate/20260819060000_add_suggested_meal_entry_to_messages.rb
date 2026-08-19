class AddSuggestedMealEntryToMessages < ActiveRecord::Migration[8.1]
  # When retrieval finds a meal you have eaten before, the assistant turn offering it
  # points at the entry it came from. A column rather than a content block because
  # `content` is replayed to the API verbatim, and a block type Anthropic doesn't know
  # is a 400 on the next request.
  def change
    add_reference :messages, :suggested_meal_entry, foreign_key: { to_table: :meal_entries }, null: true
  end
end
