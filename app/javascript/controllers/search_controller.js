import { Controller } from "@hotwired/stimulus"

// Submits the search form while you type, so the list under it answers the query as it
// grows rather than waiting for a button. The form still targets a turbo-frame, so what
// arrives back is the ranked list alone — the box you are typing in is outside the frame
// and never gets replaced, which is what keeps the caret and the keyboard where they are.
//
// Debounced because a phone keyboard emits an `input` per letter and every one of them
// costs two trigram queries against `foods` and `meal_entries`. 250ms is under the gap
// between letters typed at speed, so "havarti" is one search and not seven, and short
// enough that pausing to read feels like the list was already there.
//
// The button stays. This is an enhancement over a form that works without it, and the
// screen has to keep working when the JavaScript hasn't loaded yet — which on a phone
// that opened the app from the home screen is a real fraction of the time.
export default class extends Controller {
  static values = { delay: { type: Number, default: 250 } }

  disconnect() {
    clearTimeout(this.timer)
  }

  submit() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.element.requestSubmit(), this.delayValue)
  }
}
