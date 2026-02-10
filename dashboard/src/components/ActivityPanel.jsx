import React from "react";

export default function ActivityPanel({ activityItems, formatDate, onRefresh }) {
  return (
    <section className="panel activity-panel">
      <div className="panel-header">
        <div>
          <h2>Activity</h2>
          <p>Recent store lifecycle events.</p>
        </div>
        <button className="ghost" onClick={onRefresh}>
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
            const headline = [item.event, item.status].filter(Boolean).join(" · ");
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
                {item.detail && <div className="activity-detail">{item.detail}</div>}
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
  );
}
