# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_19_180000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"
  enable_extension "pg_trgm"

  create_table "conversations", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.bigint "last_meal_entry_id"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["last_meal_entry_id"], name: "index_conversations_on_last_meal_entry_id"
    t.index ["user_id"], name: "index_conversations_on_user_id"
  end

  create_table "exercise_entries", force: :cascade do |t|
    t.string "activity_name"
    t.decimal "calories_burned", precision: 7, scale: 2
    t.datetime "created_at", null: false
    t.integer "duration_minutes"
    t.string "external_id"
    t.datetime "performed_at", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["user_id", "external_id"], name: "index_exercise_entries_on_user_id_and_external_id", unique: true, where: "(external_id IS NOT NULL)"
    t.index ["user_id"], name: "index_exercise_entries_on_user_id"
  end

  create_table "foods", force: :cascade do |t|
    t.string "barcode"
    t.decimal "calories_per_100g", precision: 8, scale: 2
    t.decimal "carbs_per_100g", precision: 8, scale: 2
    t.datetime "created_at", null: false
    t.decimal "fat_per_100g", precision: 8, scale: 2
    t.string "name", null: false
    t.decimal "protein_per_100g", precision: 8, scale: 2
    t.jsonb "raw_ai_response"
    t.decimal "serving_g", precision: 8, scale: 2
    t.string "serving_label"
    t.string "source"
    t.datetime "updated_at", null: false
    t.index ["barcode"], name: "index_foods_on_barcode", unique: true, where: "(barcode IS NOT NULL)"
    t.index ["name"], name: "index_foods_on_name", opclass: :gin_trgm_ops, using: :gin
  end

  create_table "households", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "name", null: false
    t.datetime "updated_at", null: false
  end

  create_table "meal_entries", force: :cascade do |t|
    t.text "assumptions"
    t.decimal "calories", precision: 8, scale: 2
    t.decimal "carbs_g", precision: 7, scale: 2
    t.string "confidence"
    t.datetime "consumed_at", null: false
    t.datetime "created_at", null: false
    t.decimal "fat_g", precision: 7, scale: 2
    t.bigint "food_id"
    t.string "meal_type"
    t.decimal "protein_g", precision: 7, scale: 2
    t.decimal "quantity_grams", precision: 8, scale: 2
    t.string "raw_input"
    t.string "source", null: false
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.index ["food_id"], name: "index_meal_entries_on_food_id"
    t.index ["user_id", "consumed_at"], name: "index_meal_entries_on_user_id_and_consumed_at"
    t.index ["user_id"], name: "index_meal_entries_on_user_id"
  end

  create_table "messages", force: :cascade do |t|
    t.jsonb "content", null: false
    t.bigint "conversation_id", null: false
    t.datetime "created_at", null: false
    t.string "input_source"
    t.string "role", null: false
    t.bigint "suggested_meal_entry_id"
    t.integer "token_estimate"
    t.datetime "updated_at", null: false
    t.index ["conversation_id", "created_at"], name: "index_messages_on_conversation_id_and_created_at"
    t.index ["conversation_id"], name: "index_messages_on_conversation_id"
    t.index ["suggested_meal_entry_id"], name: "index_messages_on_suggested_meal_entry_id"
  end

  create_table "sessions", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.string "ip_address"
    t.datetime "updated_at", null: false
    t.string "user_agent"
    t.bigint "user_id", null: false
    t.index ["user_id"], name: "index_sessions_on_user_id"
  end

  create_table "users", force: :cascade do |t|
    t.datetime "calibrated_at"
    t.datetime "created_at", null: false
    t.integer "daily_calorie_target", default: 2000
    t.string "email_address", null: false
    t.decimal "estimated_tdee", precision: 7, scale: 2
    t.bigint "household_id", null: false
    t.decimal "logging_bias_factor", precision: 5, scale: 3, default: "1.0"
    t.string "name", null: false
    t.string "password_digest", null: false
    t.string "timezone", default: "America/Los_Angeles", null: false
    t.datetime "updated_at", null: false
    t.index ["email_address"], name: "index_users_on_email_address", unique: true
    t.index ["household_id"], name: "index_users_on_household_id"
  end

  create_table "weight_entries", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.datetime "recorded_at", null: false
    t.string "source"
    t.datetime "updated_at", null: false
    t.bigint "user_id", null: false
    t.decimal "weight_kg", precision: 6, scale: 2, null: false
    t.index ["user_id", "recorded_at"], name: "index_weight_entries_on_user_id_and_recorded_at"
    t.index ["user_id"], name: "index_weight_entries_on_user_id"
  end

  add_foreign_key "conversations", "meal_entries", column: "last_meal_entry_id"
  add_foreign_key "conversations", "users"
  add_foreign_key "exercise_entries", "users"
  add_foreign_key "meal_entries", "foods"
  add_foreign_key "meal_entries", "users"
  add_foreign_key "messages", "conversations"
  add_foreign_key "messages", "meal_entries", column: "suggested_meal_entry_id"
  add_foreign_key "sessions", "users"
  add_foreign_key "users", "households"
  add_foreign_key "weight_entries", "users"
end
