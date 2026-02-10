import React from "react";

export default function HeroSection({
  storesCount,
  totalReady,
  totalProvisioning,
  totalFailed,
  metrics,
}) {
  return (
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
          <span className="metric">{storesCount}</span>
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
  );
}
