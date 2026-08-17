class CreateWeightAndExerciseEntries < ActiveRecord::Migration[8.1]
  def change
    create_table :weight_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.decimal :weight_kg, null: false, precision: 6, scale: 2
      t.string :source                                  # manual | health_connect
      t.datetime :recorded_at, null: false
      t.timestamps
    end

    add_index :weight_entries, [ :user_id, :recorded_at ]

    # Exercise is deferred (design §11), but the table is cheap and the schema won't change.
    create_table :exercise_entries do |t|
      t.references :user, null: false, foreign_key: true
      t.string :activity_name
      t.integer :duration_minutes
      t.decimal :calories_burned, precision: 7, scale: 2
      t.string :source                                  # met_estimate | manual | health_connect
      t.string :external_id                             # dedupe if Health Connect ever arrives
      t.datetime :performed_at, null: false
      t.timestamps
    end

    add_index :exercise_entries, [ :user_id, :external_id ], unique: true, where: "external_id IS NOT NULL"
  end
end
