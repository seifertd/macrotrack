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
  static targets = [ "field", "source", "button", "status", "overlay", "heard", "state" ]

  // Nothing is sent on a timer any more — you press Done. This only stops the microphone
  // being held open by a button pressed in a pocket, and it stops *listening* rather than
  // sending: whatever was heard stays on screen behind the Done button, so a recording
  // nobody is watching cannot log a meal on its own.
  static QUIET_MS = 45000

  connect() {
    this.Recognition = window.SpeechRecognition || window.webkitSpeechRecognition

    if (!this.Recognition) return this.buttonTarget.remove()

    this.listening = false
  }

  disconnect() {
    this.listening = false
    this.clearTimers()
    this.close()

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
    this.show("")
    this.overlayTarget.classList.remove("hidden")
    this.stateTarget.textContent = "Listening…"
    this.say("")
    this.waitForQuiet()
  }

  heard(event) {
    this.show(this.transcript.hear(event.results))
    this.waitForQuiet()
  }

  // Restarted for as long as the overlay is open, because Android ends the session at
  // every pause whatever `continuous` says and there is no setting that changes it — the
  // one that would, EXTRA_SPEECH_INPUT_COMPLETE_SILENCE_LENGTH_MILLIS, belongs to the
  // native Intent API and is unreachable from a page. Design §6 is right that this API
  // stops on silence. What it costs is a chime on each restart, and the odd word lost in
  // the moment between one session ending and the next beginning.
  //
  // Both of those are survivable now only because the words are on screen as they land:
  // a gap is something you can see and say again, rather than something you discover
  // after the meal is logged. Not a fix — WP5-b is the fix — but honest.
  ended() {
    this.transcript.close()

    if (this.listening) {
      try {
        return this.recognition.start()
      } catch {
        // Fall through and send what we have.
      }
    }

    this.send()
  }

  // The user says when they are finished. Asking the recogniser to stop is all this does;
  // its own `end` event is still the one path that submits.
  finish() {
    this.listening = false
    this.clearTimers()
    if (this.recognition) this.recognition.stop()
  }

  cancel() {
    this.listening = false
    this.clearTimers()
    this.close()

    if (!this.recognition) return

    this.recognition.onresult = this.recognition.onerror = this.recognition.onend = null
    this.recognition.abort()
    this.recognition = null
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

  send() {
    this.listening = false
    this.clearTimers()
    this.recognition = null

    const said = this.transcript.text()
    this.fieldTarget.value = said
    this.close()

    if (said === "") return this.say(this.problem || "Didn't hear anything.")

    // The turn is only stamped as dictated once something was actually dictated, which
    // is why this is set here and not in the markup: the composer's mic and its text
    // field submit the same form, and a typed meal must not claim to be a spoken one.
    if (this.hasSourceTarget) this.sourceTarget.value = "voice"

    this.say("")
    this.element.requestSubmit()
  }

  // Stops listening without sending. The overlay stays up with whatever was heard, so
  // finishing is still a deliberate press.
  waitForQuiet() {
    this.clearTimers()
    this.timer = setTimeout(() => {
      this.listening = false
      if (this.recognition) this.recognition.stop()
      this.stateTarget.textContent = "Stopped listening — press Done to send."
    }, this.constructor.QUIET_MS)
  }

  show(said) {
    this.heardTarget.textContent = said
  }

  close() {
    this.overlayTarget.classList.add("hidden")
  }

  clearTimers() {
    if (this.timer) clearTimeout(this.timer)
    this.timer = null
  }

  say(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
