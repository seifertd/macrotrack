class CreateConversationsAndMessages < ActiveRecord::Migration[8.1]
  def change
    # One conversation per user; messages are windowed when sent to the API (design §9).
    create_table :conversations do |t|
      t.references :user, null: false, foreign_key: true
      t.references :last_meal_entry, foreign_key: { to_table: :meal_entries }
      t.timestamps
    end

    create_table :messages do |t|
      t.references :conversation, null: false, foreign_key: true
      t.string :role, null: false                       # user | assistant
      t.jsonb :content, null: false                     # raw Anthropic content blocks, replayed verbatim
      t.integer :token_estimate
      t.timestamps
    end

    add_index :messages, [ :conversation_id, :created_at ]
  end
end
