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

function provisioningStart(store) {
  if (!store) return null;
  const created = store.createdAt ? new Date(store.createdAt).getTime() : NaN;
  const updated = store.updatedAt ? new Date(store.updatedAt).getTime() : NaN;
  if (!Number.isNaN(updated) && (Number.isNaN(created) || updated > created)) {
    return updated;
  }
  if (!Number.isNaN(created)) return created;
  return null;
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

  const hasStores = stores.length > 0;
  const totalReady = useMemo(
    () => stores.filter((store) => store.status === "Ready").length,
    [stores]
  );

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

  useEffect(() => {
    fetchStores();
    const handle = setInterval(fetchStores, 5000);
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
            <span className="metric">{stores.length - totalReady}</span>
            <span className="metric-label">Provisioning</span>
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
              return (
                <article key={store.id} className="store-card">
                <div>
                  <h3>{store.name}</h3>
                  <p className="muted">{store.engine}</p>
                </div>
                <div className={statusTone[store.status] || "status"}>
                  {store.status}
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
                          <br />
                          <a href={adminUrl} target="_blank" rel="noreferrer">
                            Admin: {adminUrl}
                          </a>
                        </div>
                      );
                    })}
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
    </div>
  );
}
