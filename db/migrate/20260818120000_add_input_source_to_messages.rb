class AddInputSourceToMessages < ActiveRecord::Migration[8.1]
  # How the user's turn arrived — "text" now, "voice" from WP5. It lives on the
  # message rather than the conversation because a single thread mixes both: you
  # type a correction to something you dictated. `meal_entries.source` is copied
  # from here, so a voice-logged meal stays distinguishable from a typed one.
  def change
    add_column :messages, :input_source, :string
  end
end
