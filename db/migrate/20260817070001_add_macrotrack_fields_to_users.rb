class AddMacrotrackFieldsToUsers < ActiveRecord::Migration[8.1]
  def change
    add_reference :users, :household, null: false, foreign_key: true

    change_table :users, bulk: true do |t|
      # Short display name, shown on shared/copied entries and the "also log for X" button.
      t.string :name, null: false

      # NOT optional: every daily rollup converts consumed_at through this, so a wrong
      # value files an 11pm snack on the wrong day. Defaulted to the household's zone
      # rather than UTC so a forgotten value fails visibly rather than subtly.
      t.string :timezone, null: false, default: "America/Los_Angeles"

      t.integer :daily_calorie_target, default: 2000

      # Calibration outputs — written by the weekly job, hand-overridable (design §12).
      t.decimal :estimated_tdee, precision: 7, scale: 2
      t.decimal :logging_bias_factor, precision: 5, scale: 3, default: 1.0
      t.datetime :calibrated_at
    end
  end
end
