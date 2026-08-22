// Recorded audio, in the one format whisper.cpp will read (WP5-b).
//
// Android records webm/opus, and miniaudio — the decoder whisper.cpp uses, and the reason
// das needs no ffmpeg — reads wav, mp3 and flac but not opus. The browser already has a
// decoder and a resampler in the Web Audio API, so the conversion happens here rather
// than costing a system package on the server that would have needed a password.
//
// 16 kHz mono is what whisper works in internally, so downsampling here is not a loss:
// it is the same audio it would have resampled to anyway, at a quarter of the upload.
export const SAMPLE_RATE = 16000

// A WAV file is a 44-byte header and then the samples. Written by hand because the
// alternative is a library, and this is the shorter of the two.
export function encodeWav(samples, sampleRate = SAMPLE_RATE) {
  const buffer = new ArrayBuffer(44 + samples.length * 2)
  const view = new DataView(buffer)

  const ascii = (offset, text) => {
    for (let i = 0; i < text.length; i++) view.setUint8(offset + i, text.charCodeAt(i))
  }

  ascii(0, "RIFF")
  view.setUint32(4, 36 + samples.length * 2, true)   // everything after this field
  ascii(8, "WAVE")
  ascii(12, "fmt ")
  view.setUint32(16, 16, true)                       // fmt chunk length
  view.setUint16(20, 1, true)                        // 1 = uncompressed PCM
  view.setUint16(22, 1, true)                        // mono
  view.setUint32(24, sampleRate, true)
  view.setUint32(28, sampleRate * 2, true)           // bytes per second
  view.setUint16(32, 2, true)                        // bytes per sample frame
  view.setUint16(34, 16, true)                       // bits per sample
  ascii(36, "data")
  view.setUint32(40, samples.length * 2, true)

  // Float -1…1 to signed 16-bit. Clamped first: a sample even slightly outside the range
  // wraps rather than saturating once it is an integer, and a wrap is an audible click.
  for (let i = 0; i < samples.length; i++) {
    const sample = Math.max(-1, Math.min(1, samples[i]))

    view.setInt16(44 + i * 2, Math.round(sample * (sample < 0 ? 0x8000 : 0x7fff)), true)
  }

  return buffer
}

// Mixed to mono by averaging rather than by taking the first channel, so a phone that
// hands back two channels with the speech panned does not lose half of it.
export function toMono(channels, length) {
  if (channels.length === 1) return channels[0]

  const mixed = new Float32Array(length)

  for (let i = 0; i < length; i++) {
    let sum = 0
    for (const channel of channels) sum += channel[i]
    mixed[i] = sum / channels.length
  }

  return mixed
}

// The whole conversion, given a decoded AudioBuffer. Kept separate from the controller so
// it can be checked without a microphone; the browser-only half is getting the buffer.
export function wavFrom(audioBuffer) {
  const channels = []

  for (let i = 0; i < audioBuffer.numberOfChannels; i++) channels.push(audioBuffer.getChannelData(i))

  return encodeWav(toMono(channels, audioBuffer.length), Math.round(audioBuffer.sampleRate))
}
