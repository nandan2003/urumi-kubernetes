import React, { useEffect, useMemo, useState } from "react";

const API_BASE = import.meta.env.VITE_API_BASE || "http://localhost:8080";

const statusTone = {
  Provisioning: "status status--provisioning",
  Ready: "status status--ready",
  Failed: "status status--failed",
  Deleting: "status status--deleting",
};

const PROVISIONING_ESTIMATE_MS = 60 * 1000;
const STUCK_THRESHOLD_MS = 2 * 60 * 1000;

function formatDate(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return date.toLocaleString();
}

function parseActivityLine(line) {
  if (!line) return { raw: line, ts: null };
  try {
    const parsed = JSON.parse(line);
    const ts = parsed?.ts ? new Date(parsed.ts).getTime() : null;
    return {
      raw: line,
      ts: Number.isNaN(ts) ? null : ts,
      tsRaw: parsed?.ts || "",
      event: parsed?.event || "",
      status: parsed?.status || "",
      store: parsed?.store || parsed?.name || "",
      detail: parsed?.detail || "",
    };
  } catch {
    return { raw: line, ts: null };
  }
}

function passwordCommand(storeId) {
  return `KUBECONFIG=.kube/k3d-urumi-local.yaml kubectl -n store-${storeId} get secret urumi-${storeId}-ecommerce-store-secrets -o jsonpath='{.data.wp-admin-password}' | base64 -d`;
}

function provisioningStart(store) {
  if (!store) return null;
  if (store.status === "Ready" && store.provisionedAt) {
    const readyAt = new Date(store.provisionedAt).getTime();
    if (!Number.isNaN(readyAt)) return readyAt;
  }
  const created = store.createdAt ? new Date(store.createdAt).getTime() : NaN;
  const updated = store.updatedAt ? new Date(store.updatedAt).getTime() : NaN;
  if (!Number.isNaN(updated) && (Number.isNaN(created) || updated > created)) {
    return updated;
  }
  if (!Number.isNaN(created)) return created;
  return null;
}

function formatDuration(start, end) {
  if (!start || !end) return "-";
  const diffMs = end - start;
  if (Number.isNaN(diffMs) || diffMs < 0) return "-";
  const secs = Math.round(diffMs / 1000);
  if (secs < 60) return `${secs}s`;
  const mins = Math.floor(secs / 60);
  const rem = secs % 60;
  return `${mins}m ${rem}s`;
}

function progressForStore(store) {
  if (!store) return 0;
  if (store.status === "Ready") return 100;
  if (store.status === "Failed") return 0;
  const start = provisioningStart(store);
  if (!start) return 5;
  const elapsed = Date.now() - start;
  if (store.status === "Provisioning" && elapsed > STUCK_THRESHOLD_MS) return 100;
  const ratio = Math.min(1, Math.max(0, elapsed / PROVISIONING_ESTIMATE_MS));
  return Math.min(95, Math.max(5, Math.round(ratio * 95)));
}

function storeIsStuck(store) {
  if (!store || store.status !== "Provisioning") return false;
  const start = provisioningStart(store);
  if (!start) return false;
  return Date.now() - start > STUCK_THRESHOLD_MS;
}

export default function App() {
  const [stores, setStores] = useState([]);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState("");
  const [apiOffline, setApiOffline] = useState(false);
  const [name, setName] = useState("");
  const [engine, setEngine] = useState("woocommerce");
  const [subdomain, setSubdomain] = useState("");
  const [submitting, setSubmitting] = useState(false);
  const [passwordNotice, setPasswordNotice] = useState(null);
  const [activity, setActivity] = useState([]);
  const [metrics, setMetrics] = useState(null);

  const hasStores = stores.length > 0;
  const totalReady = useMemo(
    () => stores.filter((store) => store.status === "Ready").length,
    [stores]
  );
  const totalFailed = useMemo(
    () => stores.filter((store) => store.status === "Failed").length,
    [stores]
  );
  const totalProvisioning = stores.length - totalReady - totalFailed;
  const activityItems = useMemo(() => {
    const mapped = activity.map((line, index) => ({
      ...parseActivityLine(line),
      index,
    }));
    return mapped.sort((a, b) => {
      if (a.ts != null && b.ts != null && a.ts !== b.ts) {
        return b.ts - a.ts;
      }
      if (a.ts != null && b.ts == null) return -1;
      if (a.ts == null && b.ts != null) return 1;
      return b.index - a.index;
    });
  }, [activity]);

  const fetchStores = async () => {
    try {
      const res = await fetch(`${API_BASE}/api/stores`);
      if (!res.ok) {
        setApiOffline(false);
        throw new Error(`Failed to load stores (${res.status})`);
      }
      const data = await res.json();
      setStores(Array.isArray(data) ? data : []);
      setError("");
      setApiOffline(false);
    } catch (err) {
      const message = err?.message || "Failed to load stores";
      if (message.includes("Failed to fetch") || message.includes("NetworkError")) {
        setApiOffline(true);
        setError("");
      } else {
        setApiOffline(false);
        setError(message);
      }
    } finally {
      setLoading(false);
    }
  };

  const fetchActivity = async () => {
    try {
      const res = await fetch(`${API_BASE}/api/activity`);
      if (!res.ok) return;
      const data = await res.json();
      const events = Array.isArray(data?.events) ? data.events : [];
      setActivity(events);
    } catch {
      // ignore activity errors
    }
  };

  const fetchMetrics = async () => {
    try {
      const res = await fetch(`${API_BASE}/api/metrics`);
      if (!res.ok) return;
      const data = await res.json();
      setMetrics(data);
    } catch {
      // ignore metrics errors
    }
  };

  useEffect(() => {
    fetchStores();
    fetchActivity();
    fetchMetrics();
    const handle = setInterval(() => {
      fetchStores();
      fetchActivity();
      fetchMetrics();
    }, 5000);
    return () => clearInterval(handle);
  }, []);

  const createStore = async (event) => {
    event.preventDefault();
    if (apiOffline) {
      setError("API Offline: start the orchestrator on http://localhost:8080");
      return;
    }
    if (!name.trim()) {
      setError("Store name is required.");
      return;
    }
    setSubmitting(true);
    try {
      const res = await fetch(`${API_BASE}/api/stores`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          name,
          engine,
          subdomain,
        }),
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error(text || `Create failed (${res.status})`);
      }
      const payload = await res.json();
      const storePayload = payload?.store || payload;
      if (payload?.adminPassword && storePayload?.id) {
        setPasswordNotice({
          id: storePayload.id,
          password: payload.adminPassword,
        });
      }
      setName("");
      setSubdomain("");
      await fetchStores();
    } catch (err) {
      setError(err.message || "Failed to create store");
    } finally {
      setSubmitting(false);
    }
  };

  const deleteStore = async (id) => {
    if (!id) return;
    try {
      const res = await fetch(`${API_BASE}/api/stores/${id}`, {
        method: "DELETE",
      });
      if (!res.ok) {
        const text = await res.text();
        throw new Error(text || `Delete failed (${res.status})`);
      }
      await fetchStores();
    } catch (err) {
      setError(err.message || "Failed to delete store");
    }
  };

  return (
    <div className="app">
      <header className="hero">
        <div>
          <p className="eyebrow">Urumi Kubernetes Store Provisioning</p>
          <h1>Provision stores in minutes, not weeks.</h1>
          <p className="subtitle">
            Kubernetes-native orchestration with Helm-backed deployments.
          </p>
        </div>
        <div className="hero-card">
          <div>
            <span className="metric">{stores.length}</span>
            <span className="metric-label">Active Stores</span>
          </div>
          <div>
            <span className="metric">{totalReady}</span>
            <span className="metric-label">Ready</span>
          </div>
          <div>
            <span className="metric">{totalProvisioning}</span>
            <span className="metric-label">Provisioning</span>
          </div>
          <div>
            <span className="metric">{totalFailed}</span>
            <span className="metric-label">Failed</span>
          </div>
          <div>
            <span className="metric">
              {metrics?.provisioningSeconds?.avg
                ? `${metrics.provisioningSeconds.avg.toFixed(0)}s`
                : "-"}
            </span>
            <span className="metric-label">Avg Provision</span>
          </div>
          <div>
            <span className="metric">
              {metrics?.provisioningSeconds?.p95
                ? `${metrics.provisioningSeconds.p95.toFixed(0)}s`
                : "-"}
            </span>
            <span className="metric-label">P95 Provision</span>
          </div>
        </div>
      </header>

      {apiOffline && (
        <section className="panel api-offline">
          <h2>API Offline</h2>
          <p>
            The orchestrator is not reachable at <strong>{API_BASE}</strong>. Start it with
            <code>STORAGE_CLASS=local-path go run .</code> from <code>orchestrator/</code>.
          </p>
        </section>
      )}

      <section className="panel create-panel">
        <div>
          <h2>Create a new store</h2>
          <p>Choose an engine and claim a subdomain.</p>
        </div>
        <form className="create-form" onSubmit={createStore}>
          <label>
            Store name
            <input
              type="text"
              placeholder="Midnight Bikes"
              value={name}
              onChange={(event) => setName(event.target.value)}
            />
          </label>
          <label>
            Engine
            <select value={engine} onChange={(event) => setEngine(event.target.value)}>
              <option value="woocommerce">WooCommerce</option>
              <option value="medusa">Medusa (stub)</option>
            </select>
          </label>
          <label>
            Subdomain (optional)
            <input
              type="text"
              placeholder="midnight-bikes"
              value={subdomain}
              onChange={(event) => setSubdomain(event.target.value)}
            />
          </label>
          <button type="submit" disabled={submitting}>
            {submitting ? "Provisioning…" : "Create Store"}
          </button>
        </form>
        {error && <p className="error">{error}</p>}
      </section>

      {passwordNotice && (
        <section className="panel password-notice">
          <div className="notice-row">
            <div>
              <h2>Initial admin password</h2>
              <p>
                Store <strong>{passwordNotice.id}</strong>:{" "}
                <code>{passwordNotice.password}</code>
              </p>
              <p className="muted">
                If you change the password in WordPress, this value will no longer
                work. Retrieve the original password with:
              </p>
              <code>{passwordCommand(passwordNotice.id)}</code>
            </div>
            <button className="ghost" onClick={() => setPasswordNotice(null)}>
              Dismiss
            </button>
          </div>
        </section>
      )}

      <section className="panel stores-panel">
        <div className="panel-header">
          <div>
            <h2>Stores</h2>
            <p>Watch provisioning status and manage lifecycle.</p>
          </div>
          <button className="ghost" onClick={fetchStores} disabled={loading}>
            Refresh
          </button>
        </div>

        {loading ? (
          <div className="empty">Loading stores…</div>
        ) : !hasStores ? (
          <div className="empty">No stores provisioned yet.</div>
        ) : (
          <div className="store-grid">
            {stores.map((store) => {
              const isStuck = storeIsStuck(store);
              const progress = progressForStore(store);
              const displayStatus =
                store.status === "Provisioning" && store.wasReady
                  ? "Restarting"
                  : store.status;
              const createdAt = store.createdAt ? new Date(store.createdAt).getTime() : null;
              const provisionedAt = store.provisionedAt ? new Date(store.provisionedAt).getTime() : null;
              return (
                <article key={store.id} className="store-card">
                <div>
                  <h3>{store.name}</h3>
                  <p className="muted">{store.engine}</p>
                </div>
                <div className={statusTone[store.status] || "status"}>
                  {displayStatus}
                </div>
                <div className="store-meta">
                  <div>
                    <span className="label">Store ID: </span>
                    <span>{store.id}</span>
                  </div>
                  <div>
                    <span className="label">Namespace: </span>
                    <span>{store.namespace}</span>
                  </div>
                  <div>
                    <span className="label">Created At: </span>
                    <span>{formatDate(store.createdAt)}</span>
                  </div>
                  <div>
                    <span className="label">Progress (est.): </span>
                    <span>
                      {progress}%{isStuck ? " (Stuck - Check Logs)" : ""}
                    </span>
                  </div>
                  <div>
                    <span className="label">Provisioning time: </span>
                    <span>{formatDuration(createdAt, provisionedAt)}</span>
                  </div>
                </div>
                <div className="progress">
                  <div
                    className={`progress-bar${isStuck ? " progress-bar--stuck" : ""}`}
                    style={{ width: `${progress}%` }}
                  />
                </div>
                {store.status === "Ready" && (
                  <div className="store-links">
                    {(store.urls || []).map((url) => {
                      const trimmed = url.replace(/\/+$/, "");
                      const adminUrl = `${trimmed}/wp-admin/`;
                      return (
                        <div key={url}>
                          <a href={url} target="_blank" rel="noreferrer">
                            Shop: {url}
                          </a>
                          {store.engine === "woocommerce" && (
                            <>
                              <br />
                              <a href={adminUrl} target="_blank" rel="noreferrer">
                                Admin: {adminUrl}
                              </a>
                            </>
                          )}
                        </div>
                      );
                    })}
                    {store.engine === "woocommerce" && (
                      <p className="muted">
                        Initial admin password (if unchanged):{" "}
                        <code>{passwordCommand(store.id)}</code>
                      </p>
                    )}
                  </div>
                )}
                {store.error && <p className="error">{store.error}</p>}
                <button className="danger" onClick={() => deleteStore(store.id)}>
                  Delete
                </button>
                </article>
              );
            })}
          </div>
        )}
      </section>

      <section className="panel activity-panel">
        <div className="panel-header">
          <div>
            <h2>Activity</h2>
            <p>Recent store lifecycle events.</p>
          </div>
          <button className="ghost" onClick={fetchActivity}>
            Refresh
          </button>
        </div>
        {activityItems.length === 0 ? (
          <div className="empty">No activity yet.</div>
        ) : (
          <div className="activity-list">
            {activityItems.map((item) => {
              const isError =
                item.status === "Failed" ||
                item.event.includes("failed") ||
                item.event.includes("error");
              const headline = [item.event, item.status]
                .filter(Boolean)
                .join(" · ");
              const when = item.tsRaw ? formatDate(item.tsRaw) : "-";
              return (
                <div
                  key={`${item.raw}-${item.index}`}
                  className={`activity-row${isError ? " activity-row--error" : ""}`}
                >
                  <div className="activity-main">
                    <span className="activity-event">{headline || "Event"}</span>
                  </div>
                  <div className="activity-meta">
                    <span>Store: {item.store || "-"}</span>
                    <span>When: {when}</span>
                  </div>
                  {item.detail && (
                    <div className="activity-detail">{item.detail}</div>
                  )}
                  {!item.detail && !item.event && (
                    <div className="activity-detail">
                      <code>{item.raw}</code>
                    </div>
                  )}
                </div>
              );
            })}
          </div>
        )}
      </section>
    </div>
  );
}
