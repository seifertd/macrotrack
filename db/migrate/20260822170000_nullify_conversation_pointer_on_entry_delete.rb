# The chat keeps a pointer at the last entry it logged. Nothing reads it yet, but its
# foreign key was enough to make deleting that entry a 500 — you cannot delete the meal
# you just logged by voice, which is exactly the one you would want to.
#
# Nullify at the database rather than only in the model, so it holds for a rake task, a
# console session and a cascade as well as for the controller.
class NullifyConversationPointerOnEntryDelete < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :conversations, :meal_entries, column: :last_meal_entry_id
    add_foreign_key :conversations, :meal_entries, column: :last_meal_entry_id, on_delete: :nullify
  end

  def down
    remove_foreign_key :conversations, :meal_entries, column: :last_meal_entry_id
    add_foreign_key :conversations, :meal_entries, column: :last_meal_entry_id
  end
end
