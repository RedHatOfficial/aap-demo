"use strict";

const state = {
  sessionToken: "",
  payload: null,
  activeCategory: "All",
  polling: null,
  dismissedOperationId: null,
  dismissTimer: null,
  restarting: false,
  refreshing: false,
};

const elements = {
  alert: document.querySelector("#alert"),
  addonGrid: document.querySelector("#addon-grid"),
  categoryFilter: document.querySelector("#category-filter"),
  capacityGrid: document.querySelector("#capacity-grid"),
  capacityMessage: document.querySelector("#capacity-message"),
  capacityPanel: document.querySelector("#capacity-panel"),
  capacityStatus: document.querySelector("#capacity-status"),
  clusterIndicator: document.querySelector("#cluster-indicator"),
  clusterState: document.querySelector("#cluster-state"),
  clusterSummary: document.querySelector("#cluster-summary"),
  environmentOs: document.querySelector("#environment-os"),
  lastUpdated: document.querySelector("#last-updated"),
  namespaceList: document.querySelector("#namespace-list"),
  operationDetails: document.querySelector("#operation-details"),
  operationDismiss: document.querySelector("#operation-dismiss"),
  operationMessage: document.querySelector("#operation-message"),
  operationOutput: document.querySelector("#operation-output"),
  operationPanel: document.querySelector("#operation-panel"),
  operationStatus: document.querySelector("#operation-status"),
  refreshButton: document.querySelector("#refresh-button"),
  restartButton: document.querySelector("#restart-button"),
  routesList: document.querySelector("#routes-list"),
  summaryGrid: document.querySelector("#summary-grid"),
};

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    ...options,
    headers: {
      "Content-Type": "application/json",
      ...(state.sessionToken ? {"X-AAP-Demo-Token": state.sessionToken} : {}),
      ...(options.headers || {}),
    },
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Request failed with status ${response.status}`);
  }
  return payload;
}

function showAlert(message) {
  elements.alert.textContent = message;
  elements.alert.classList.remove("hidden");
}

function clearAlert() {
  elements.alert.textContent = "";
  elements.alert.classList.add("hidden");
}

function summaryCard(label, value, tone = "") {
  return `<article class="summary-card ${escapeHtml(tone)}"><span>${escapeHtml(label)}</span><strong>${escapeHtml(value)}</strong></article>`;
}

function renderSummary(inventory) {
  const cluster = inventory.cluster;
  const running = cluster.state === "running";
  elements.clusterIndicator.className = `status-dot ${running ? "running" : "stopped"}`;
  elements.clusterState.textContent = running ? "Cluster running" : `Cluster ${cluster.state}`;
  elements.clusterSummary.textContent =
    `${cluster.name || "Local cluster"} · Kubernetes ${cluster.kubernetes_version} · ${inventory.host.architecture}`;
  elements.environmentOs.textContent =
    `Host OS: ${inventory.host.os || "Unknown"}` +
    (cluster.vm?.guest_os ? ` · CRC guest OS: ${cluster.vm.guest_os}` : "") +
    (inventory.host.aap_subscription ? ` · AAP subscription: ${inventory.host.aap_subscription}` : "");

  const healthyNamespaces = inventory.namespaces.filter((namespace) => namespace.ready).length;
  const readyPods = inventory.pods.filter(
    (pod) => pod.phase === "Running" && pod.ready_containers === pod.total_containers,
  ).length;
  const capacity = inventory.storage?.capacity_planning || {};
  const disk = capacity.actual_vm_disk_gib == null
    ? (cluster.vm?.disk || "Unavailable")
    : `${capacity.actual_vm_used_gib} / ${capacity.actual_vm_disk_gib} GiB`;
  const diskPercent = capacity.actual_vm_disk_gib
    ? Math.round((capacity.actual_vm_used_gib / capacity.actual_vm_disk_gib) * 100)
    : Number.parseInt(String(disk).match(/\((\d+)% used\)/)?.[1] || "0", 10);
  const diskTone = diskPercent >= 90 ? "critical" : diskPercent >= 80 ? "warning" : "";
  const fleetV2Count = (inventory.fleet_v2 || []).length;
  const fleetTotal = (inventory.fleet || []).length + fleetV2Count;
  elements.summaryGrid.innerHTML = [
    summaryCard("Namespaces ready", `${healthyNamespaces}/${inventory.namespaces.length}`),
    summaryCard("Pods ready", `${readyPods}/${inventory.pods.length}`),
    summaryCard("Active routes", inventory.routes.filter((route) => route.admitted).length),
    summaryCard("Fleet nodes", fleetTotal || "0"),
    summaryCard("Disk usage", disk, diskTone),
    summaryCard("Python v2 CLI", inventory.tool?.v2_available ? "Available" : "Not installed"),
  ].join("");
}

function formatGib(value) {
  return value == null ? "Unavailable" : `${value} GiB`;
}

function renderCapacity(inventory) {
  const capacity = inventory.storage?.capacity_planning;
  if (!capacity) {
    elements.capacityPanel.classList.add("hidden");
    return;
  }
  elements.capacityPanel.classList.remove("hidden", "warning");
  const undersized = capacity.needs_rebuild;
  const pendingConfig = capacity.configured_not_applied;
  if (undersized || pendingConfig) {
    elements.capacityPanel.classList.add("warning");
  }
  elements.capacityStatus.className = `pill ${undersized || pendingConfig ? "degraded" : "running"}`;
  elements.capacityStatus.textContent = undersized ? "Undersized" : pendingConfig ? "Config not applied" : "Planned";
  elements.capacityGrid.innerHTML = [
    summaryCard("Current VM disk", formatGib(capacity.actual_vm_disk_gib)),
    summaryCard("VM free", formatGib(capacity.actual_vm_free_gib), undersized ? "critical" : ""),
    summaryCard("Recommended", formatGib(capacity.recommended_vm_disk_gib), undersized ? "warning" : ""),
    summaryCard("Host-only estimate", formatGib(capacity.host_only_gib)),
  ].join("");
  if (undersized) {
    elements.capacityMessage.textContent =
      `This VM is below the ${capacity.recommended_vm_disk_gib} GiB planning recommendation for the enabled add-ons. ` +
      "This planning estimate is not a resize trigger. At 90% disk usage, aap-demo start adds 20% capacity after checking host space and gracefully stopping CRC; no destructive rebuild is required.";
  } else if (pendingConfig) {
    elements.capacityMessage.textContent =
      `Configured CRC disk (${capacity.configured_crc_disk_gib} GiB) does not match the existing VM. ` +
      "A supported disk-size increase takes effect on the next stopped-VM CRC start. Separately, aap-demo start checks for 90% disk usage and adds 20% capacity when needed; it never rebuilds the VM automatically.";
  } else {
    elements.capacityMessage.textContent =
      "Conservative planning estimates include safety headroom and are not exact product requirements. Host-only storage is separate from the CRC VM.";
  }
}

function renderCategories(addons) {
  const categories = ["All", ...new Set(addons.map((addon) => addon.category))];
  elements.categoryFilter.innerHTML = categories
    .map(
      (category) =>
        `<button class="filter-button ${category === state.activeCategory ? "active" : ""}" ` +
        `type="button" data-category="${escapeHtml(category)}">${escapeHtml(category)}</button>`,
    )
    .join("");
  elements.categoryFilter.querySelectorAll("button").forEach((button) => {
    button.addEventListener("click", () => {
      state.activeCategory = button.dataset.category;
      renderCategories(addons);
      renderAddons(addons);
    });
  });
}

function stateLabel(addonState) {
  return {
    running: "Running",
    enabled: "Configured",
    degraded: "Needs attention",
    disabled: "Disabled",
  }[addonState] || "Unknown";
}

function renderAddons(addons) {
  const operationRunning = state.payload?.operation?.status === "running";
  const filtered = addons.filter(
    (addon) => state.activeCategory === "All" || addon.category === state.activeCategory,
  );
  elements.addonGrid.innerHTML = filtered
    .map((addon) => {
      const dependencies = addon.active_dependencies?.length
        ? `Dependencies: ${addon.active_dependencies.join(", ")}`
        : "No add-on dependencies";
      const availability = addon.availability ? ` · ${addon.availability}` : "";
      const estimate = addon.capacity_estimate || {};
      const capacityText = addon.enabled
        ? `VM allowance: ${estimate.vm_gib ?? 0} GiB`
        : `Projected recommendation: ${addon.projected_vm_disk_gib ?? "?"} GiB` +
          (estimate.host_gib ? ` · Host-only: ${estimate.host_gib} GiB` : "");
      const button = addon.supported === false
        ? '<button class="button" type="button" disabled>Unavailable on Windows</button>'
        : addon.enabled
        ? `<button class="button danger" type="button" data-action="disable" data-addon="${addon.id}" ${operationRunning ? "disabled" : ""}>Disable</button>`
        : `<button class="button primary" type="button" data-action="enable" data-addon="${addon.id}" ${operationRunning ? "disabled" : ""}>Enable</button>`;
      return `
        <article class="addon-card">
          <div class="addon-heading">
            <h3>${escapeHtml(addon.name)}</h3>
            <span class="pill ${escapeHtml(addon.state)}">${escapeHtml(stateLabel(addon.state))}</span>
          </div>
          <p class="category">${escapeHtml(addon.category)}</p>
          <p class="description">${escapeHtml(addon.description)}</p>
          <p class="addon-meta">${escapeHtml(dependencies + availability)}</p>
          <p class="addon-capacity">${escapeHtml(capacityText)}</p>
          <div class="addon-footer">
            <span class="muted">${escapeHtml(addon.short_name || addon.id)}</span>
            ${button}
          </div>
        </article>`;
    })
    .join("");
  elements.addonGrid.querySelectorAll("button[data-action]").forEach((button) => {
    button.addEventListener("click", () => toggleAddon(button.dataset.addon, button.dataset.action));
  });
}

function renderRoutes(routes, fleet = [], fleetV2 = []) {
  if (!routes.length && !fleet.length && !fleetV2.length) {
    elements.routesList.innerHTML = '<p class="empty-state">No application routes found.</p>';
    return;
  }
  elements.routesList.innerHTML = routes
    .map(
      (route) => `
        <div class="route-row">
          <div>
            <a href="${escapeHtml(route.url)}" target="_blank" rel="noreferrer">${escapeHtml(route.url)}</a>
            <span class="route-name">${escapeHtml(route.namespace)} / ${escapeHtml(route.name)}</span>
          </div>
          <span class="pill ${route.admitted ? "running" : "degraded"}">${route.admitted ? "Admitted" : "Pending"}</span>
        </div>`,
    )
    .join("") + fleet.map((node) => `
      <div class="route-row">
        <div>
          <a href="/terminal?node=${encodeURIComponent(node.index)}" target="_blank" rel="noopener noreferrer">
            ${escapeHtml(node.hostname)} - SSH terminal
          </a>
          <span class="route-name">admin@${escapeHtml(node.ssh_host)}:${escapeHtml(node.ssh_port)}
            / guest IP ${escapeHtml(node.guest_ip || "not discovered")}</span>
          <span class="fleet-power" role="group" aria-label="Power controls for ${escapeHtml(node.hostname)}">
            <button class="power-btn" type="button" title="Start ${escapeHtml(node.hostname)}"
              data-node="${node.index}" data-power="start" aria-label="Start">▶</button>
            <button class="power-btn" type="button" title="Stop ${escapeHtml(node.hostname)}"
              data-node="${node.index}" data-power="stop" aria-label="Stop">⏹</button>
            <button class="power-btn" type="button" title="Restart ${escapeHtml(node.hostname)}"
              data-node="${node.index}" data-power="restart" aria-label="Restart">⟳</button>
          </span>
        </div>
        <span class="pill ${node.state === "running" ? "running" : "disabled"}">${escapeHtml(node.state)}</span>
      </div>`).join("") + fleetV2.map((node) => `
      <div class="route-row">
        <div>
          <span class="fleet-v2-name">${escapeHtml(node.name)}</span>
          <span class="route-name">Kubernetes-native fleet · ${escapeHtml(node.namespace)}
            / pod IP ${escapeHtml(node.pod_ip || "pending")}</span>
        </div>
        <span class="pill ${node.ready ? "running" : "degraded"}">${escapeHtml(node.state)}</span>
      </div>`).join("");
  elements.routesList.querySelectorAll("button[data-power]").forEach((button) => {
    button.addEventListener("click", () => fleetPower(button.dataset.node, button.dataset.power, button));
  });
}

function renderNamespaces(namespaces) {
  if (!namespaces.length) {
    elements.namespaceList.innerHTML = '<p class="empty-state">No application namespaces found.</p>';
    return;
  }
  elements.namespaceList.innerHTML = namespaces
    .map(
      (namespace) => `
        <div class="namespace-row">
          <div>
            <div class="namespace-name">${escapeHtml(namespace.name)}</div>
            <div class="namespace-count">${namespace.running_pods}/${namespace.total_pods} running</div>
          </div>
          <span class="pill ${namespace.ready ? "running" : "degraded"}">${namespace.ready ? "Ready" : "Attention"}</span>
        </div>`,
    )
    .join("");
}

function renderOperation(operation) {
  elements.restartButton.disabled = state.restarting || operation?.status === "running";
  if (
    !operation ||
    operation.status === "idle" ||
    (operation.id === state.dismissedOperationId && operation.status !== "running")
  ) {
    elements.operationPanel.className = "operation-panel hidden";
    return;
  }
  elements.operationPanel.className = "operation-panel";
  if (operation.status === "succeeded") {
    elements.operationPanel.classList.add("complete");
  } else if (operation.status === "failed") {
    elements.operationPanel.classList.add("failed");
  }
  elements.operationMessage.textContent = operation.message;
  elements.operationStatus.textContent = operation.status;
  elements.operationStatus.className =
    `pill ${operation.status === "running" ? "running-operation" : operation.status === "succeeded" ? "running" : "degraded"}`;
  elements.operationDismiss.classList.toggle("hidden", operation.status === "running");
  if (operation.output) {
    elements.operationOutput.textContent = operation.output;
    elements.operationDetails.classList.remove("hidden");
  } else {
    elements.operationOutput.textContent = "";
    elements.operationDetails.classList.add("hidden");
  }
  if (operation.status === "succeeded" && !state.dismissTimer) {
    state.dismissTimer = window.setTimeout(() => {
      state.dismissedOperationId = operation.id;
      state.dismissTimer = null;
      renderOperation(operation);
    }, 12000);
  }
}

function render(payload) {
  state.payload = payload;
  renderSummary(payload.inventory);
  renderCapacity(payload.inventory);
  renderCategories(payload.addons);
  renderAddons(payload.addons);
  renderRoutes(payload.inventory.routes, payload.inventory.fleet || [], payload.inventory.fleet_v2 || []);
  renderNamespaces(payload.inventory.namespaces);
  renderOperation(payload.operation);
  elements.lastUpdated.textContent = `Updated ${new Date().toLocaleTimeString()}`;
}

async function refresh() {
  // Skip when a refresh is already in flight: aap-demo status --json can take
  // ~30s against a settling cluster, and overlapping fetches pile up server-side
  // and leave the UI showing an empty/stale payload (e.g. "Active routes: 0").
  if (state.restarting || state.refreshing) {
    return;
  }
  state.refreshing = true;
  elements.refreshButton.disabled = true;
  try {
    const payload = await api("/api/status");
    clearAlert();
    render(payload);
  } catch (error) {
    showAlert(error.message);
  } finally {
    state.refreshing = false;
    elements.refreshButton.disabled = false;
  }
}

async function toggleAddon(addonId, action) {
  if (state.restarting) {
    return;
  }
  if (action === "disable") {
    const confirmed = window.confirm(
      `Disable ${addonId}? Workloads will be removed, but retained data and credentials will be preserved where supported.`,
    );
    if (!confirmed) {
      return;
    }
  }
  clearAlert();
  try {
    state.dismissedOperationId = null;
    if (state.dismissTimer) {
      clearTimeout(state.dismissTimer);
      state.dismissTimer = null;
    }
    await api(`/api/addons/${encodeURIComponent(addonId)}/${action}`, {
      method: "POST",
      body: JSON.stringify({confirm: action === "disable"}),
    });
    await refresh();
    startOperationPolling();
  } catch (error) {
    showAlert(error.message);
  }
}

async function fleetPower(nodeIndex, action, button) {
  if (state.restarting) {
    return;
  }
  const label = {start: "Start", stop: "Stop", restart: "Restart"}[action] || action;
  if (action !== "start") {
    const confirmed = window.confirm(`${label} fleet node ${nodeIndex}?`);
    if (!confirmed) {
      return;
    }
  }
  clearAlert();
  const buttons = elements.routesList.querySelectorAll(`button[data-node="${nodeIndex}"]`);
  buttons.forEach((btn) => { btn.disabled = true; });
  try {
    await api(`/api/fleet/${encodeURIComponent(nodeIndex)}/power`, {
      method: "POST",
      body: JSON.stringify({action}),
    });
    await refresh();
  } catch (error) {
    showAlert(error.message);
    buttons.forEach((btn) => { btn.disabled = false; });
  }
}

async function restartDashboard() {
  if (state.restarting) {
    return;
  }
  state.restarting = true;
  elements.restartButton.disabled = true;
  elements.restartButton.textContent = "Restarting...";
  elements.refreshButton.disabled = true;
  showAlert("Restarting the dashboard only. CRC and AAP will keep running.");
  try {
    const previous = await api("/api/health");
    await api("/api/restart", {method: "POST", body: "{}"});
    const deadline = Date.now() + 30000;
    while (Date.now() < deadline) {
      await new Promise((resolve) => window.setTimeout(resolve, 500));
      try {
        const health = await api("/api/health", {signal: AbortSignal.timeout(2000)});
        if (health.instance !== previous.instance) {
          window.location.reload();
          return;
        }
      } catch {
        // The listener is briefly unavailable while the server replaces itself.
      }
    }
    throw new Error("Dashboard restart timed out. Check dashboard.log or run 'aap-demo dashboard --no-open'.");
  } catch (error) {
    showAlert(error.message);
    state.restarting = false;
    elements.restartButton.disabled = state.payload?.operation?.status === "running";
    elements.restartButton.textContent = "Restart dashboard";
    elements.refreshButton.disabled = false;
  }
}

function startOperationPolling() {
  if (state.polling) {
    clearInterval(state.polling);
  }
  state.polling = window.setInterval(async () => {
    try {
      const operation = await api("/api/operation");
      renderOperation(operation);
      if (operation.status !== "running") {
        clearInterval(state.polling);
        state.polling = null;
        await refresh();
      }
    } catch (error) {
      showAlert(error.message);
    }
  }, 2000);
}

async function initialize() {
  try {
    const session = await api("/api/session");
    state.sessionToken = session.token;
    await refresh();
    if (state.payload?.operation?.status === "running") {
      startOperationPolling();
    }
    // Poll no faster than the slowest status collection; refresh() also
    // self-skips while one is in flight, so this only fires when idle.
    window.setInterval(() => {
      if (!state.polling) {
        refresh();
      }
    }, 45000);
  } catch (error) {
    showAlert(error.message);
  }
}

elements.refreshButton.addEventListener("click", refresh);
elements.restartButton.addEventListener("click", restartDashboard);
elements.operationDismiss.addEventListener("click", () => {
  const operation = state.payload?.operation;
  if (operation) {
    state.dismissedOperationId = operation.id;
    renderOperation(operation);
  }
});
document.addEventListener("visibilitychange", () => {
  if (document.visibilityState === "visible") {
    refresh();
  }
});
window.addEventListener("focus", refresh);
initialize();
