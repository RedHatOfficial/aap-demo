"use strict";

(async () => {
  const status = document.querySelector("#terminal-status");
  const index = new URLSearchParams(window.location.search).get("node");
  let sessionId;
  let token;
  let stopped = false;
  let pending = "";
  let terminal;

  async function request(path, body) {
    const response = await fetch(path, {
      method: "POST",
      headers: {"Content-Type": "application/json", "X-AAP-Demo-Token": token},
      body: JSON.stringify(body),
      cache: "no-store",
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || "Terminal request failed");
    return result;
  }

  async function disconnect() {
    stopped = true;
    document.querySelector("#disconnect").disabled = true;
    if (sessionId) {
      await request(`/api/terminals/${sessionId}/io`, {close: true});
      sessionId = null;
    }
    status.textContent = "Disconnected";
  }

  document.querySelector("#disconnect").addEventListener("click", () => {
    disconnect().catch((error) => { status.textContent = error.message; });
  });
  window.addEventListener("pagehide", () => {
    if (!sessionId) return;
    fetch(`/api/terminals/${sessionId}/io`, {
      method: "POST",
      headers: {"Content-Type": "application/json", "X-AAP-Demo-Token": token},
      body: JSON.stringify({close: true}),
      keepalive: true,
    }).catch((error) => {
      console.error("Terminal disconnect failed; the server will expire the session", error);
    });
  });

  try {
    if (!/^[1-9][0-9]*$/.test(index || "")) throw new Error("Invalid Fleet node");
    if (!window.Terminal || !window.FitAddon) {
      throw new Error("Terminal assets missing: run npm ci --prefix dashboard, then reload");
    }
    document.querySelector("#terminal-title").textContent = `Fleet node ${index} - admin SSH`;
    token = (await (await fetch("/api/session", {cache: "no-store"})).json()).token;
    terminal = new window.Terminal({cursorBlink: true, fontSize: 15});
    const fit = new window.FitAddon.FitAddon();
    terminal.loadAddon(fit);
    terminal.open(document.querySelector("#ssh-terminal"));
    fit.fit();
    window.addEventListener("resize", () => fit.fit());
    terminal.onData((data) => {
      if (new TextEncoder().encode(pending + data).length > 2048) {
        status.textContent = "Input buffer full; paste smaller chunks";
        return;
      }
      pending += data;
    });
    sessionId = (await request(`/api/fleet/${index}/terminal`, {})).id;
    document.querySelector("#disconnect").disabled = false;
    status.textContent = "Connected over localhost. Close or disconnect when finished.";
    terminal.focus();
    while (!stopped) {
      const data = pending;
      pending = "";
      const result = await request(`/api/terminals/${sessionId}/io`, {
        data, cols: terminal.cols, rows: terminal.rows,
      });
      if (result.output) {
        terminal.write(Uint8Array.from(atob(result.output), (character) => character.charCodeAt(0)));
      }
      if (result.exited) {
        await disconnect();
        break;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  } catch (error) {
    if (stopped) return;
    stopped = true;
    status.textContent = error.message;
    if (sessionId) {
      try {
        await request(`/api/terminals/${sessionId}/io`, {close: true});
      } catch (closeError) {
        status.textContent += `; cleanup failed: ${closeError.message}`;
      }
    }
  }
})();
