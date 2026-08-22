import { Controller } from "@hotwired/stimulus"
import Transcript from "lib/transcript"

// Tap, ramble, done (WP5-a).
//
// The recogniser is the browser's own, reached through `webkitSpeechRecognition`. That is
// the entire package: no endpoint, no provider, no blob, and nothing of ours to keep
// running. Chrome does the recognising on Google's servers rather than on the handset —
// worth knowing, and a smaller step than it sounds next to sending the same sentence to
// Anthropic a moment later. WP5-b is where a hosted recogniser with vocabulary biasing
// would go, and it stays unbuilt until this one is measured and found wanting.
//
// Failure ends where WP7's does — in the composer you were going to type into anyway.
// Unlike the barcode screen there is nothing to explain when the browser can't do it: a
// phone with no recogniser still has a keyboard with a mic key, so the button is simply
// not rendered rather than rendered and apologetic.
export default class extends Controller {
  static targets = ["field", "source", "button", "status"]

  // How long a pause means "finished" rather than "thinking". Long enough to say
  // "…and, uh…" in the middle of a sentence without being cut off, short enough that
  // you aren't left wondering whether it heard you.
  static SILENCE_MS = 2500

  // Describing a meal does not take a minute, and a recogniser started by a pocket
  // should stop on its own rather than hold the mic open until the tab closes.
  static LIMIT_MS = 60000

  connect() {
    this.Recognition = window.SpeechRecognition || window.webkitSpeechRecognition

    if (!this.Recognition) return this.buttonTarget.remove()

    this.listening = false
  }

  disconnect() {
    this.listening = false
    this.clearTimers()

    if (!this.recognition) return

    // Unhooked before aborting: abort() fires `end`, and `end` is the path that submits.
    this.recognition.onresult = this.recognition.onerror = this.recognition.onend = null
    this.recognition.abort()
  }

  toggle() {
    this.listening ? this.finish() : this.start()
  }

  start() {
    this.transcript = new Transcript()
    this.problem = null
    this.listening = true
    this.deadline = Date.now() + this.constructor.LIMIT_MS

    this.recognition = new this.Recognition()
    this.recognition.lang = document.documentElement.lang || "en-US"
    this.recognition.continuous = true
    this.recognition.interimResults = true
    this.recognition.onresult = (event) => this.heard(event)
    this.recognition.onerror = (event) => this.failed(event)
    this.recognition.onend = () => this.ended()

    try {
      this.recognition.start()
    } catch {
      // Already running, which means a double tap got through. Nothing to do.
      return
    }

    this.fieldTarget.value = ""
    this.buttonTarget.classList.add("animate-pulse", "ring-2", "ring-rose-400")
    this.say("Listening… tap again when you're done.")
    this.waitForSilence()
  }

  heard(event) {
    this.fieldTarget.value = this.transcript.hear(event.results)
    this.waitForSilence()
  }

  // Safari ends a session at the first pause whatever `continuous` claims, and Chrome
  // will too if the pause is long enough. Restarting keeps the sentence going, so it is
  // the silence timer below — not the browser's idea of a sentence — that decides when
  // you have finished talking.
  ended() {
    this.transcript.close()

    if (this.listening && Date.now() < this.deadline) {
      try {
        return this.recognition.start()
      } catch {
        // Fall through and send what we have.
      }
    }

    this.send()
  }

  failed(event) {
    this.listening = false

    // no-speech is what a quiet room reports, and aborted is us. Neither is worth a
    // line of red text; the rest are, because "nothing happened" is the worst answer a
    // button can give.
    if (event.error === "not-allowed" || event.error === "service-not-allowed") {
      this.problem = "Microphone access was refused. Allow it, or type it instead."
    } else if (event.error === "network") {
      this.problem = "Speech recognition needs a connection. Type it instead."
    } else if (event.error !== "no-speech" && event.error !== "aborted") {
      this.problem = "Didn't catch that. Try again, or type it instead."
    }
  }

  // Asks the recogniser to stop; the session's own `end` event does the sending, so
  // there is exactly one path out and it is the same one silence takes.
  finish() {
    this.listening = false
    this.clearTimers()
    if (this.recognition) this.recognition.stop()
  }

  send() {
    this.listening = false
    this.clearTimers()
    this.recognition = null
    this.buttonTarget.classList.remove("animate-pulse", "ring-2", "ring-rose-400")

    const said = this.transcript.text()
    this.fieldTarget.value = said

    if (said === "") return this.say(this.problem || "Didn't hear anything.")

    // The turn is only stamped as dictated once something was actually dictated, which
    // is why this is set here and not in the markup: the composer's mic and its text
    // field submit the same form, and a typed meal must not claim to be a spoken one.
    if (this.hasSourceTarget) this.sourceTarget.value = "voice"

    this.say("")
    this.element.requestSubmit()
  }

  waitForSilence() {
    this.clearTimers()
    this.timer = setTimeout(() => this.finish(), this.constructor.SILENCE_MS)
  }

  clearTimers() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  say(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
