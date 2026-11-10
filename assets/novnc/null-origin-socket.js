// SPDX-FileCopyrightText: Copyright (c) 2026 XPeta Lab
// SPDX-License-Identifier: GPL-3.0-only

/**
 * A WebSocket-shaped channel for noVNC (`new RFB(target, channel)`) whose real
 * socket lives in a sandboxed iframe (`ws-relay.html`, `sandbox=allow-scripts`
 * without `allow-same-origin`), so the handshake carries `Origin: null`.
 *
 * The Dashboard refuses a WebSocket whose http(s) Origin is not the host it is
 * bound to, and this page is served from https://appassets.androidplatform.net;
 * a non-web Origin is what Hermes trusts for packaged apps (Desktop's file://,
 * app://), the credential (the display ticket) being the boundary
 * (`hermes_cli/web_server_boundary.py` `ws_host_origin_reason`). REVIEW-R5-B #4.
 */
export default class NullOriginSocket {
  constructor(url, relaySrc = './ws-relay.html', doc = document) {
    this.binaryType = 'arraybuffer';
    this.onopen = null;
    this.onmessage = null;
    this.onerror = null;
    this.onclose = null;
    this._state = 0; // CONNECTING
    this._protocol = '';
    const channel = new MessageChannel();
    this._port = channel.port1;
    this._port.onmessage = (event) => this._receive(event.data);
    const frame = doc.createElement('iframe');
    frame.setAttribute('sandbox', 'allow-scripts');
    frame.setAttribute('aria-hidden', 'true');
    frame.tabIndex = -1;
    frame.hidden = true;
    frame.addEventListener(
      'load',
      () => frame.contentWindow.postMessage(
        { t: 'connect', url },
        '*',
        [channel.port2],
      ),
      { once: true },
    );
    frame.src = relaySrc;
    doc.body.appendChild(frame);
    this._frame = frame;
  }

  get readyState() {
    return this._state;
  }

  get protocol() {
    return this._protocol;
  }

  send(data) {
    if (this._state !== 1) return;
    // noVNC sends views of a buffer it reuses: copy only the bytes, then hand
    // that copy over.
    const bytes = data instanceof ArrayBuffer
      ? new Uint8Array(data).slice()
      : new Uint8Array(data.buffer, data.byteOffset, data.byteLength).slice();
    this._port.postMessage({ t: 'send', data: bytes.buffer }, [bytes.buffer]);
  }

  close(code, reason) {
    if (this._state >= 2) return;
    this._state = 2; // CLOSING
    this._port.postMessage({ t: 'close', code, reason });
  }

  _receive(message) {
    if (!message) return;
    switch (message.t) {
      case 'open':
        this._state = 1; // OPEN
        this._protocol = message.protocol || '';
        if (this.onopen) this.onopen({ type: 'open' });
        break;
      case 'message':
        if (this.onmessage) this.onmessage({ type: 'message', data: message.data });
        break;
      case 'error':
        if (this.onerror) this.onerror({ type: 'error' });
        break;
      case 'close':
        this._state = 3; // CLOSED
        if (this.onclose) {
          this.onclose({
            type: 'close',
            code: message.code,
            reason: message.reason || '',
            wasClean: message.wasClean === true,
          });
        }
        this._port.close();
        this._frame.remove();
        break;
      default:
        break;
    }
  }
}
