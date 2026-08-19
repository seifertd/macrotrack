import { Controller } from "@hotwired/stimulus"

// Camera → barcode → lookup (WP7).
//
// `BarcodeDetector` is native in Chrome on Android and does the decoding on-device, for
// free, with no library to ship. It does not exist in Safari; both phones in this
// household are Android, so there is no JS fallback here — the typed-number form below
// the camera is the fallback, and it is a plain server-rendered GET so it still works
// when everything in this file fails.
//
// Every failure path ends the same way: say what happened in one line, leave the typed
// form alone. A camera that will not start is an inconvenience, not a dead end.
export default class extends Controller {
  static targets = ["stage", "video", "status"]
  static values = { basePath: String }

  // EAN-13/8 and UPC-A/E cover essentially everything on a supermarket shelf. Limiting
  // the set keeps the detector off QR codes on the same packet.
  static FORMATS = ["ean_13", "ean_8", "upc_a", "upc_e"]

  async connect() {
    this.stopped = false

    if (!("BarcodeDetector" in window)) {
      return this.giveUp("This browser can't scan barcodes. Type the number instead.")
    }

    try {
      const supported = await window.BarcodeDetector.getSupportedFormats()
      const formats = this.constructor.FORMATS.filter((f) => supported.includes(f))

      if (formats.length === 0) {
        return this.giveUp("This browser can't read product barcodes. Type the number instead.")
      }

      this.detector = new window.BarcodeDetector({ formats })
      await this.startCamera()
    } catch (error) {
      this.giveUp(this.messageFor(error))
    }
  }

  disconnect() {
    this.stop()
  }

  async startCamera() {
    // `environment` asks for the back camera. Android honours it; if it can't, we get
    // the front one rather than an error, which is worth having over failing outright.
    this.stream = await navigator.mediaDevices.getUserMedia({
      video: { facingMode: "environment" }
    })

    if (this.stopped) return this.stop()

    this.videoTarget.srcObject = this.stream
    await this.videoTarget.play()

    this.stageTarget.classList.remove("hidden")
    this.statusTarget.textContent = "Looking for a barcode…"

    this.scan()
  }

  // requestAnimationFrame rather than setInterval: it pauses when the tab is backgrounded,
  // which is exactly when we should not be holding the camera open and burning battery.
  scan() {
    if (this.stopped) return

    this.frame = requestAnimationFrame(async () => {
      try {
        const codes = await this.detector.detect(this.videoTarget)
        const code = codes.map((c) => c.rawValue).find((v) => /^\d{6,14}$/.test(v))

        if (code) return this.found(code)
      } catch {
        // A dropped frame is normal — the video element is not always ready. Keep going.
      }

      this.scan()
    })
  }

  found(code) {
    this.stop()
    this.statusTarget.textContent = `Found ${code}. Looking it up…`

    // Turbo would work here too, but a full visit keeps the back button behaving like
    // "back to the camera" rather than replaying a detection.
    window.location.assign(`${this.basePathValue}/${code}`)
  }

  giveUp(message) {
    this.stop()
    this.stageTarget.classList.add("hidden")
    this.statusTarget.textContent = message
  }

  stop() {
    this.stopped = true

    if (this.frame) cancelAnimationFrame(this.frame)
    if (this.stream) this.stream.getTracks().forEach((track) => track.stop())

    this.stream = null
  }

  messageFor(error) {
    if (error.name === "NotAllowedError") {
      return "Camera access was refused. Type the number instead, or allow the camera and reload."
    }
    if (error.name === "NotFoundError") {
      return "No camera on this device. Type the number instead."
    }

    return "Couldn't start the camera. Type the number instead."
  }
}
