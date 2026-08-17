class CreateFoods < ActiveRecord::Migration[8.1]
  def change
    create_table :foods do |t|
      t.string :name, null: false
      t.string :source                                  # usda | openfoodfacts | ai_estimate | user_custom
      t.string :barcode                                 # nil unless scanned

      t.decimal :calories_per_100g, precision: 8, scale: 2
      t.decimal :protein_per_100g, precision: 8, scale: 2
      t.decimal :fat_per_100g, precision: 8, scale: 2
      t.decimal :carbs_per_100g, precision: 8, scale: 2

      # Full response kept deliberately — the only thing that makes a bad parse
      # debuggable three weeks later.
      t.jsonb :raw_ai_response

      t.timestamps
    end

    add_index :foods, :barcode, unique: true, where: "barcode IS NOT NULL"
    add_index :foods, :name, using: :gin, opclass: :gin_trgm_ops
  end
end
