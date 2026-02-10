import React from "react";

export default function StoresPanel({
  stores,
  loading,
  hasStores,
  statusTone,
  storeIsStuck,
  progressForStore,
  formatDate,
  formatDuration,
  passwordCommand,
  onRefresh,
  onDelete,
}) {
  return (
    <section className="panel stores-panel">
      <div className="panel-header">
        <div>
          <h2>Stores</h2>
          <p>Watch provisioning status and manage lifecycle.</p>
        </div>
        <button className="ghost" onClick={onRefresh} disabled={loading}>
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
            const provisionedAt = store.provisionedAt
              ? new Date(store.provisionedAt).getTime()
              : null;
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
                <button className="danger" onClick={() => onDelete(store.id)}>
                  Delete
                </button>
              </article>
            );
          })}
        </div>
      )}
    </section>
  );
}
