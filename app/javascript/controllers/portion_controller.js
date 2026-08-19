import { Controller } from "@hotwired/stimulus"

// Shows what the portion comes to before it is saved. The arithmetic is deliberately
// the same shape as MealPortion's — scale every figure by one factor — so the preview
// and the row that gets written can't disagree.
export default class extends Controller {
  static targets = ["grams", "multiplier", "chip", "calories", "protein", "fat", "carbs"]
  static values = { calories: Number, protein: Number, fat: Number, carbs: Number, grams: Number }

  connect() {
    this.recalculate()
  }

  // A chip sets the grams field when there is one, so the input stays the single source
  // of truth and you can still nudge it afterwards.
  choose(event) {
    const multiplier = Number(event.currentTarget.dataset.multiplier)

    if (this.hasGramsTarget && this.gramsValue > 0) {
      this.gramsTarget.value = Math.round(this.gramsValue * multiplier)
    } else if (this.hasMultiplierTarget) {
      this.multiplierTarget.value = multiplier
    }

    this.recalculate()
  }

  recalculate() {
    const factor = this.factor()

    this.caloriesTarget.textContent = Math.round(this.caloriesValue * factor).toLocaleString()
    this.proteinTarget.textContent = `${Math.round(this.proteinValue * factor)}g`
    this.fatTarget.textContent = `${Math.round(this.fatValue * factor)}g`
    this.carbsTarget.textContent = `${Math.round(this.carbsValue * factor)}g`
  }

  factor() {
    if (this.hasGramsTarget && this.gramsValue > 0) {
      const grams = Number(this.gramsTarget.value)
      return grams > 0 ? grams / this.gramsValue : 1
    }

    return this.hasMultiplierTarget ? Number(this.multiplierTarget.value) || 1 : 1
  }
}
