import React from "react";

export default function ApiOfflineNotice({ apiBase }) {
  return (
    <section className="panel api-offline">
      <h2>API Offline</h2>
      <p>
        The orchestrator is not reachable at <strong>{apiBase}</strong>. Start it
        with <code>STORAGE_CLASS=local-path go run .</code> from{" "}
        <code>orchestrator/</code>.
      </p>
    </section>
  );
}
