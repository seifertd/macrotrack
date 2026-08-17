class CreateMealEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :meal_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.references :food, null: true, foreign_key: true

      t.string :raw_input                               # what was typed, or the voice transcript
      t.string :source, null: false                     # barcode | matched | photo | voice | text | manual | copied

      t.decimal :quantity_grams, precision: 8, scale: 2
      t.decimal :calories, precision: 8, scale: 2
      t.decimal :protein_g, precision: 7, scale: 2
      t.decimal :fat_g, precision: 7, scale: 2
      t.decimal :carbs_g, precision: 7, scale: 2

      t.string :meal_type                               # breakfast | lunch | dinner | snack

      # Both shown in the UI — surfacing uncertainty rather than hiding it (design §2).
      t.string :confidence                              # high | medium | low
      t.text :assumptions

      t.datetime :consumed_at, null: false
      t.timestamps
    end

    add_index :meal_entries, [ :user_id, :consumed_at ]
  end
end
