import React from "react";

export default function PasswordNotice({ notice, onDismiss, passwordCommand }) {
  return (
    <section className="panel password-notice">
      <div className="notice-row">
        <div>
          <h2>Initial admin password</h2>
          <p>
            Store <strong>{notice.id}</strong>: <code>{notice.password}</code>
          </p>
          <p className="muted">
            If you change the password in WordPress, this value will no longer
            work. Retrieve the original password with:
          </p>
          <code>{passwordCommand(notice.id)}</code>
        </div>
        <button className="ghost" onClick={onDismiss}>
          Dismiss
        </button>
      </div>
    </section>
  );
}
