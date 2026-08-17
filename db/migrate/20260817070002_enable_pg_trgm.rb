class EnablePgTrgm < ActiveRecord::Migration[8.1]
  # Trigram similarity backs repeat-meal matching (design §7 path 1), which is the
  # highest-leverage path in the app. Needs postgresql-contrib installed server-side.
  def change
    enable_extension "pg_trgm"
  end
end
