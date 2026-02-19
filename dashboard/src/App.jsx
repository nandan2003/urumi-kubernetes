import React, { useEffect, useMemo, useState } from "react";
import ActivityPanel from "./components/ActivityPanel";
import AiChat from "./components/AiChat";
import ApiOfflineNotice from "./components/ApiOfflineNotice";
import CreateStorePanel from "./components/CreateStorePanel";
import HeroSection from "./components/HeroSection";
import PasswordNotice from "./components/PasswordNotice";
import StoresPanel from "./components/StoresPanel";

const API_BASE = import.meta.env.VITE_API_BASE || "http://localhost:8080";
const AI_BASE = import.meta.env.VITE_AI_URL || "/ai";

const statusTone = {
  Provisioning: "status status--provisioning",
  Ready: "status status--ready",
  Failed: "status status--failed",
  Deleting: "status status--deleting",
};

const PROVISIONING_ESTIMATE_MS = 60 * 1000;
const STUCK_THRESHOLD_MS = 2 * 60 * 1000;
const INFRA_ERROR_RE = /(forbidden|rbac|rolebinding|serviceaccount|pods\/exec|authorization\.k8s\.io|x509|certificate signed by unknown authority|unable to connect to the server|context \"?.*\"? does not exist|connection refused|timed out|tls)/i;

function sanitizeInfrastructureError(message) {
  if (!message) return "";
  const text = String(message);
  if (INFRA_ERROR_RE.test(text)) {
    return "Provisioning failed due to an internal cluster access issue. Please retry or restart the stack.";
  }
  return text;
}

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
    const detail = sanitizeInfrastructureError(parsed?.detail || "");
    return {
      raw: line,
      ts: Number.isNaN(ts) ? null : ts,
      tsRaw: parsed?.ts || "",
      event: parsed?.event || "",
      status: parsed?.status || "",
      store: parsed?.store || parsed?.name || "",
      detail,
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
      const normalized = (Array.isArray(data) ? data : []).map((store) => ({
        ...store,
        error: sanitizeInfrastructureError(store?.error || ""),
      }));
      setStores(normalized);
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
      <aside className="sidebar">
        <AiChat apiUrl={AI_BASE} />
      </aside>

      <main className="main-content">
        <HeroSection
          storesCount={stores.length}
          totalReady={totalReady}
          totalProvisioning={totalProvisioning}
          totalFailed={totalFailed}
          metrics={metrics}
        />

        {apiOffline && <ApiOfflineNotice apiBase={API_BASE} />}

        <CreateStorePanel
          name={name}
          engine={engine}
          subdomain={subdomain}
          submitting={submitting}
          error={error}
          onNameChange={(event) => setName(event.target.value)}
          onEngineChange={(event) => setEngine(event.target.value)}
          onSubdomainChange={(event) => setSubdomain(event.target.value)}
          onSubmit={createStore}
        />

        {passwordNotice && (
          <PasswordNotice
            notice={passwordNotice}
            onDismiss={() => setPasswordNotice(null)}
            passwordCommand={passwordCommand}
          />
        )}

        <StoresPanel
          stores={stores}
          loading={loading}
          hasStores={hasStores}
          statusTone={statusTone}
          storeIsStuck={storeIsStuck}
          progressForStore={progressForStore}
          formatDate={formatDate}
          formatDuration={formatDuration}
          passwordCommand={passwordCommand}
          onRefresh={fetchStores}
          onDelete={deleteStore}
        />

        <ActivityPanel
          activityItems={activityItems}
          formatDate={formatDate}
          onRefresh={fetchActivity}
        />
      </main>
    </div>
  );
}
