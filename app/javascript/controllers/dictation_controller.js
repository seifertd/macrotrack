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

  // A backstop, not the main way a recording ends. Android decides that itself, at the
  // first real pause; this only matters if it never says so, or if a button pressed by a
  // pocket is left listening to a quiet room.
  static SILENCE_MS = 2500

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

    this.recognition = new this.Recognition()
    this.recognition.lang = document.documentElement.lang || "en-US"
    // Explicitly off, because Android ignores it being on and the pretence cost us: see
    // `ended` below for what asking for continuous recognition actually bought.
    this.recognition.continuous = false
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
    this.say("Listening… say it in one go — a pause ends it.")
    this.waitForSilence()
  }

  heard(event) {
    this.fieldTarget.value = this.transcript.hear(event.results)
    this.waitForSilence()
  }

  // One tap is one utterance, and that is a concession rather than a design.
  //
  // This used to restart the recogniser whenever a session ended, so that a pause
  // mid-sentence would not end the recording. It does not work. Android ends the session
  // at every pause whatever `continuous` says, plays its own chime on each new one, and
  // loses whatever is said in the gap between the two — so a rambling sentence came back
  // beeping at the user with words missing from the middle. Design §6 called this
  // exactly, under the heading "Don't use the Web Speech API", and building around it
  // rather than reading it is how we got here.
  //
  // So the recording now ends when Android says it ended. Short sentences — which is
  // nearly all of them — are unaffected, and rambling is what WP5-b is for.
  ended() {
    this.transcript.close()
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
