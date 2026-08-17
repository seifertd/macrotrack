class CreateHouseholds < ActiveRecord::Migration[8.1]
  # A household is the unit that shares a kitchen — the scope for "also log this for
  # someone else". Deliberately NOT assuming the app has exactly two users: retrofitting
  # this later would mean backfilling every scoped query, and it costs one table now.
  def change
    create_table :households do |t|
      t.string :name, null: false
      t.timestamps
    end
  end
end
