class AddServingToFoods < ActiveRecord::Migration[8.1]
  # What one serving of this food weighs, and what to call it.
  #
  # `foods` is per-100g and `meal_entries.quantity_grams` is grams, which is the right
  # canonical unit — it composes, it scales, and it never needs a lookup table. But it is
  # not how anyone reads a label or eats a tub, and the conversion has been lossy in a way
  # that mattered: source data that is stated *per serving* (the EasyFit export, most
  # nutrition labels) had to be divided by a weight to be stored, and the original figure
  # could not be recovered afterwards. Keeping the serving weight makes that reversible.
  #
  # Nullable on purpose. A recipe cooked in a pot has no serving weight until someone
  # weighs it, and most chat-logged foods never will — those keep working in grams.
  def change
    add_column :foods, :serving_g, :decimal, precision: 8, scale: 2
    add_column :foods, :serving_label, :string
  end
end
