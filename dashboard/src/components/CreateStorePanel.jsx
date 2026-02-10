import React from "react";

export default function CreateStorePanel({
  name,
  engine,
  subdomain,
  submitting,
  error,
  onNameChange,
  onEngineChange,
  onSubdomainChange,
  onSubmit,
}) {
  return (
    <section className="panel create-panel">
      <div>
        <h2>Create a new store</h2>
        <p>Choose an engine and claim a subdomain.</p>
      </div>
      <form className="create-form" onSubmit={onSubmit}>
        <label>
          Store name
          <input
            type="text"
            placeholder="Midnight Bikes"
            value={name}
            onChange={onNameChange}
          />
        </label>
        <label>
          Engine
          <select value={engine} onChange={onEngineChange}>
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
            onChange={onSubdomainChange}
          />
        </label>
        <button type="submit" disabled={submitting}>
          {submitting ? "Provisioning…" : "Create Store"}
        </button>
      </form>
      {error && <p className="error">{error}</p>}
    </section>
  );
}
