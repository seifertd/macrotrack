# Design §16 gave conversations a pointer at the entry the chat logged most recently, and
# nothing ever read it: corrections reach update_meal through the meal_entry_id in the
# tool result, and the day's log now reaches the model through the prompt. What the
# pointer did do was carry a foreign key, which made deleting the entry it pointed at —
# always the one just logged, always the one you most want to delete — a 500 in
# production on 22 August.
#
# So it goes. The design doc still describes it; if a reader ever needs it, the `down`
# here puts it back with the nullifying key it should have had from the start.
class RemoveLastMealEntryFromConversations < ActiveRecord::Migration[8.1]
  def up
    remove_column :conversations, :last_meal_entry_id
  end

  def down
    add_reference :conversations, :last_meal_entry,
      foreign_key: { to_table: :meal_entries, on_delete: :nullify }
  end
end
