import { Controller } from "@hotwired/stimulus"
import { wavFrom, SAMPLE_RATE } from "lib/wav"

// Tap, ramble, done (WP5-b).
//
// This used to be the browser's own recogniser, and design §6 was right that it cannot do
// this: Android ends the session at every pause, chimes each time it is restarted, and
// loses whatever is said in between. Two rounds of working around that produced a
// recording that beeped at the user with words missing from the middle.
//
// So the microphone is ours now. MediaRecorder runs from the first tap to Done with
// nothing interrupting it — no chime, no truncation, no gap — and the audio goes to
// whisper.cpp on our own box, which transcribes a twenty-second ramble in about twelve
// seconds and gets "IKEA meatballs" right.
//
// What we give up is the live transcript: the words arrive after you finish rather than
// as you speak. That is the trade for never losing any of them, and it is why the overlay
// shows the sound of your voice instead — you still need to know it is hearing you.
export default class extends Controller {
  static targets = [ "form", "audio", "button", "status", "overlay", "state", "level", "clock" ]

  // Nobody describes a meal for two minutes, and a recording left running by a pocket
  // should stop on its own rather than upload something enormous.
  static LIMIT_MS = 120000

  connect() {
    if (!this.supported) this.buttonTarget.remove()

    this.recording = false
  }

  disconnect() {
    this.release()
  }

  get supported() {
    return typeof MediaRecorder !== "undefined" && navigator.mediaDevices?.getUserMedia
  }

  toggle() {
    if (!this.recording) this.start()
  }

  async start() {
    this.chunks = []
    this.say("")

    try {
      this.stream = await navigator.mediaDevices.getUserMedia({ audio: true })
    } catch (error) {
      return this.say(error.name === "NotAllowedError"
        ? "Microphone access was refused. Allow it, or type it instead."
        : "Couldn't start the microphone. Type it instead.")
    }

    this.recording = true
    this.recorder = new MediaRecorder(this.stream)
    this.recorder.ondataavailable = (event) => event.data.size && this.chunks.push(event.data)
    this.recorder.onstop = () => this.finished()
    this.recorder.start()

    this.open()
    this.meter()
    this.tick()
    this.limit = setTimeout(() => this.finish(), this.constructor.LIMIT_MS)
  }

  // Done. Stopping the recorder is all this does; its own `stop` event is the one path
  // that uploads, so cancelling and finishing cannot race each other.
  finish() {
    if (!this.recording) return

    this.recording = false
    this.stateTarget.textContent = "Transcribing… this takes a few seconds."
    this.recorder.stop()
  }

  cancel() {
    this.recording = false
    this.chunks = []
    if (this.recorder && this.recorder.state !== "inactive") this.recorder.stop()
    this.release()
    this.close()
  }

  async finished() {
    this.release()

    const recorded = new Blob(this.chunks, { type: this.recorder.mimeType })
    this.chunks = []

    if (recorded.size === 0) {
      this.close()
      return this.say("Nothing was recorded.")
    }

    try {
      this.attach(await this.wav(recorded))
    } catch {
      this.close()
      return this.say("Couldn't read that recording. Try again, or type it.")
    }

    this.formTarget.requestSubmit()
  }

  // webm/opus in, 16 kHz mono wav out. The browser owns a decoder and a resampler already
  // — using them is what lets whisper.cpp read the upload directly, and keeps ffmpeg, and
  // the password installing it would have needed, off the server.
  async wav(recorded) {
    const context = new (window.AudioContext || window.webkitAudioContext)()

    try {
      const decoded = await context.decodeAudioData(await recorded.arrayBuffer())
      const offline = new OfflineAudioContext(1, Math.ceil(decoded.duration * SAMPLE_RATE), SAMPLE_RATE)
      const source = offline.createBufferSource()

      source.buffer = decoded
      source.connect(offline.destination)
      source.start()

      return wavFrom(await offline.startRendering())
    } finally {
      context.close()
    }
  }

  // A file input rather than a fetch, so Turbo submits it and handles the response the
  // same way it handles the composer beside it.
  attach(wav) {
    const transfer = new DataTransfer()

    transfer.items.add(new File([ wav ], "recording.wav", { type: "audio/wav" }))
    this.audioTarget.files = transfer.files
  }

  // The overlay's whole job, now that there are no words to show yet: proof it can hear
  // you. The ring follows what the microphone is actually receiving, so silence looks
  // like silence and a dead microphone looks dead.
  meter() {
    const context = new (window.AudioContext || window.webkitAudioContext)()
    const analyser = context.createAnalyser()

    analyser.fftSize = 512
    context.createMediaStreamSource(this.stream).connect(analyser)

    const samples = new Uint8Array(analyser.frequencyBinCount)
    const draw = () => {
      if (!this.recording) return context.close()

      analyser.getByteTimeDomainData(samples)

      // Loudest departure from silence in this frame; 128 is the zero line for 8-bit.
      const peak = samples.reduce((loudest, s) => Math.max(loudest, Math.abs(s - 128)), 0)

      this.levelTarget.style.transform = `scale(${1 + Math.min(peak / 40, 1.1)})`
      this.frame = requestAnimationFrame(draw)
    }

    draw()
  }

  tick() {
    this.startedAt = Date.now()

    this.clock = setInterval(() => {
      const seconds = Math.floor((Date.now() - this.startedAt) / 1000)

      this.clockTarget.textContent = `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`
    }, 250)
  }

  open() {
    this.overlayTarget.classList.remove("hidden")
    this.stateTarget.textContent = "Recording…"
    this.clockTarget.textContent = "0:00"
  }

  close() {
    this.overlayTarget.classList.add("hidden")
    this.levelTarget.style.transform = ""
  }

  // The microphone indicator stays lit until every track is stopped, and a phone that says
  // it is still listening after you pressed Done is not one you would use again.
  release() {
    if (this.frame) cancelAnimationFrame(this.frame)
    if (this.clock) clearInterval(this.clock)
    if (this.limit) clearTimeout(this.limit)

    this.frame = this.clock = this.limit = null
    this.recording = false

    if (this.stream) this.stream.getTracks().forEach((track) => track.stop())
    this.stream = null
  }

  say(message) {
    if (this.hasStatusTarget) this.statusTarget.textContent = message
  }
}
