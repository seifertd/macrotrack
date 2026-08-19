import { Controller } from "@hotwired/stimulus"

// Keeps the newest message in view. Turbo appends messages from a broadcast rather
// than a page load, so there is no navigation to hang a scroll off — watching the
// list for added children is what covers both the initial render and every stream.
export default class extends Controller {
  static targets = ["list"]

  connect() {
    this.observer = new MutationObserver(() => this.scrollToBottom())
    this.observer.observe(this.listTarget, { childList: true, subtree: true })
    this.scrollToBottom()
  }

  disconnect() {
    this.observer?.disconnect()
  }

  scrollToBottom() {
    window.scrollTo({ top: document.body.scrollHeight, behavior: "smooth" })
  }
}
