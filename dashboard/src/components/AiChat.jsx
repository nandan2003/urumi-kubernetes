import React, { useEffect, useMemo, useRef, useState } from "react";

const DEFAULT_AI_URL = "/ai";

function parseNdjsonChunk(buffer) {
  const lines = buffer.split("\n");
  const remaining = lines.pop();
  const events = lines
    .map((line) => line.trim())
    .filter(Boolean)
    .map((line) => {
      try {
        return JSON.parse(line);
      } catch {
        return null;
      }
    })
    .filter(Boolean);
  return { events, remaining };
}

function parseNdjsonFallback(rawText) {
  if (!rawText) return [];
  let cleaned = rawText.replace(/^data:\\s*/gm, "").trim();
  if (!cleaned) return [];
  let unwrapped = false;
  // If the server returned a JSON-encoded string, unescape it first.
  if (
    (cleaned.startsWith("\"") && cleaned.endsWith("\"")) ||
    (cleaned.startsWith("'") && cleaned.endsWith("'"))
  ) {
    try {
      cleaned = JSON.parse(cleaned);
      unwrapped = true;
    } catch {
      // fall through with original text
    }
  }
  if (unwrapped && typeof cleaned === "string") {
    cleaned = cleaned.replace(/\\\\n/g, "\n").replace(/\\\\\"/g, "\"");
  }
  if (!cleaned) return [];
  // If multiple JSON objects are concatenated with literal "\\n", split them.
  cleaned = cleaned.replace(/}\\n(?=\\s*\\{)/g, "}\n").replace(/}\\r\\n(?=\\s*\\{)/g, "}\n");
  const tryParse = (text) => {
    try {
      const obj = JSON.parse(text);
      return obj && typeof obj === "object" ? [obj] : [];
    } catch {
      return [];
    }
  };

  // First try direct parse.
  const direct = tryParse(cleaned);
  if (direct.length) return direct;

  // Try NDJSON split.
  const lines = cleaned.split(/\\r?\\n+/).map((line) => line.trim()).filter(Boolean);
  const events = [];
  for (const line of lines) {
    const parsed = tryParse(line);
    if (parsed.length) events.push(parsed[0]);
  }
  if (events.length) return events;

  // As a last resort, extract JSON objects by brace matching.
  const extracted = [];
  let depth = 0;
  let start = -1;
  let inString = false;
  let escape = false;
  for (let i = 0; i < cleaned.length; i += 1) {
    const ch = cleaned[i];
    if (escape) {
      escape = false;
      continue;
    }
    if (ch === "\\\\") {
      escape = true;
      continue;
    }
    if (ch === "\"") {
      inString = !inString;
    }
    if (inString) continue;
    if (ch === "{") {
      if (depth === 0) start = i;
      depth += 1;
    } else if (ch === "}") {
      depth -= 1;
      if (depth === 0 && start >= 0) {
        extracted.push(cleaned.slice(start, i + 1));
        start = -1;
      }
    }
  }
  for (const item of extracted) {
    const parsed = tryParse(item);
    if (parsed.length) events.push(parsed[0]);
  }
  return events;
}

function renderInlineMarkdown(text, keyPrefix) {
  const parts = String(text).split(/(`[^`]+`|\*\*[^*]+\*\*|\*[^*]+\*)/g);
  return parts.map((part, idx) => {
    if (!part) return null;
    if (part.startsWith("`") && part.endsWith("`")) {
      return (
        <code key={`${keyPrefix}-c-${idx}`}>
          {part.slice(1, -1)}
        </code>
      );
    }
    if (part.startsWith("**") && part.endsWith("**")) {
      return <strong key={`${keyPrefix}-b-${idx}`}>{part.slice(2, -2)}</strong>;
    }
    if (part.startsWith("*") && part.endsWith("*")) {
      return <em key={`${keyPrefix}-i-${idx}`}>{part.slice(1, -1)}</em>;
    }
    return <span key={`${keyPrefix}-t-${idx}`}>{part}</span>;
  });
}

function splitTableRow(line) {
  let row = line.trim();
  if (row.startsWith("|")) row = row.slice(1);
  if (row.endsWith("|")) row = row.slice(0, -1);
  return row.split("|").map((cell) => cell.trim());
}

function isTableSeparator(line) {
  return /^\s*\|?\s*:?-+:?\s*(\|\s*:?-+:?\s*)+\|?\s*$/.test(line);
}

function renderMarkdownBlocks(text) {
  try {
    const lines = String(text || "").split("\n");
    const elements = [];
    let i = 0;

    while (i < lines.length) {
      const rawLine = (lines[i] || "").replace(/\r$/, "");
      const lineTrim = rawLine.trim();
      const lineTrimStart = rawLine.replace(/^\s+/, "");
      if (!lineTrim) {
        i += 1;
        continue;
      }

      // Code block
      if (lineTrimStart.startsWith("```")) {
        const fence = lineTrimStart;
        const lang = fence.replace(/```+/, "").trim();
        let j = i + 1;
        const block = [];
        while (j < lines.length && !String(lines[j] || "").trim().startsWith("```")) {
          block.push(String(lines[j] || "").replace(/\r$/, ""));
          j += 1;
        }
        elements.push(
          <pre key={`code-${i}`} data-lang={lang || undefined}>
            <code>{block.join("\n")}</code>
          </pre>
        );
        i = j + 1;
        continue;
      }

      // Table block
      if (lineTrim.includes("|") && i + 1 < lines.length && isTableSeparator(lines[i + 1])) {
        const header = splitTableRow(lineTrim);
        let j = i + 2;
        const rows = [];
        while (j < lines.length) {
          const rowLine = String(lines[j] || "").replace(/\r$/, "");
          if (!rowLine.trim() || !rowLine.includes("|")) break;
          rows.push(splitTableRow(rowLine));
          j += 1;
        }
        elements.push(
          <table key={`table-${i}`} className="ai-chat__table">
            <thead>
              <tr>
                {header.map((cell, idx) => (
                  <th key={`th-${i}-${idx}`}>{renderInlineMarkdown(cell, `th-${i}-${idx}`)}</th>
                ))}
              </tr>
            </thead>
            <tbody>
              {rows.map((row, rIdx) => (
                <tr key={`tr-${i}-${rIdx}`}>
                  {row.map((cell, cIdx) => (
                    <td key={`td-${i}-${rIdx}-${cIdx}`}>
                      {renderInlineMarkdown(cell, `td-${i}-${rIdx}-${cIdx}`)}
                    </td>
                  ))}
                </tr>
              ))}
            </tbody>
          </table>
        );
        i = j;
        continue;
      }

      // Heading
      const headingMatch = lineTrimStart.match(/^(#{1,6})\s+(.*)$/);
      if (headingMatch) {
        const level = headingMatch[1].length;
        const content = headingMatch[2] || "";
        const Tag = `h${level}`;
        elements.push(
          <Tag key={`h-${i}`} className="ai-chat__heading">
            {renderInlineMarkdown(content, `h-${i}`)}
          </Tag>
        );
        i += 1;
        continue;
      }

      // Lists
      const listMatch = lineTrimStart.match(/^\s*([-*+]|\d+\.)\s+(.*)$/);
      if (listMatch) {
        const ordered = /\d+\./.test(listMatch[1]);
        const items = [];
        let j = i;
        while (j < lines.length) {
          const m = String(lines[j] || "")
            .replace(/\r$/, "")
            .replace(/^\s+/, "")
            .match(/^\s*([-*+]|\d+\.)\s+(.*)$/);
          if (!m) break;
          items.push(m[2]);
          j += 1;
        }
        const ListTag = ordered ? "ol" : "ul";
        elements.push(
          <ListTag key={`list-${i}`} className="ai-chat__list">
            {items.map((item, idx) => (
              <li key={`li-${i}-${idx}`}>{renderInlineMarkdown(item, `li-${i}-${idx}`)}</li>
            ))}
          </ListTag>
        );
        i = j;
        continue;
      }

      // Paragraph
      const paragraphLines = [rawLine];
      let j = i + 1;
      while (j < lines.length) {
        const nextLine = String(lines[j] || "").replace(/\r$/, "");
        const nextTrim = nextLine.trim();
        if (!nextTrim || nextTrim.startsWith("```")) break;
        if (
          isTableSeparator(nextLine) ||
          nextLine.replace(/^\s+/, "").match(/^\s*([-*+]|\d+\.)\s+/) ||
          nextLine.replace(/^\s+/, "").match(/^(#{1,6})\s+/)
        ) {
          break;
        }
        paragraphLines.push(nextLine);
        j += 1;
      }
      const paragraph = paragraphLines.join("\n");
      elements.push(
        <p key={`p-${i}`} className="ai-chat__paragraph">
          {paragraph.split("\n").map((part, idx) => (
            <span key={`p-${i}-${idx}`}>
              {renderInlineMarkdown(part, `p-${i}-${idx}`)}
              {idx < paragraphLines.length - 1 ? <br /> : null}
            </span>
          ))}
        </p>
      );
      i = j;
    }
    return elements;
  } catch (err) {
    return [<span key="md-fallback">{String(text || "")}</span>];
  }
}

export default function AiChat({ apiUrl }) {
  const endpoint = apiUrl || DEFAULT_AI_URL;
  const [sessionId] = useState(() => {
    const existing = localStorage.getItem("aiSessionId");
    if (existing) return existing;
    const generated =
      (typeof crypto !== "undefined" && crypto.randomUUID && crypto.randomUUID()) ||
      `session-${Date.now()}-${Math.random().toString(16).slice(2)}`;
    localStorage.setItem("aiSessionId", generated);
    return generated;
  });
  const [input, setInput] = useState("");
  const [messages, setMessages] = useState([]);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState("");
  const [pendingConfirm, setPendingConfirm] = useState(false);
  const [taskPlan, setTaskPlan] = useState(null);
  const endRef = useRef(null);
  const historyRef = useRef(null);
  const autoScrollRef = useRef(false);

  const canSend = useMemo(() => input.trim().length > 0 && !loading, [input, loading]);
  const taskStats = useMemo(() => {
    if (!taskPlan || !Array.isArray(taskPlan.tasks)) {
      return { total: 0, completed: 0, progress: 0 };
    }
    const total = taskPlan.tasks.length;
    const completed = taskPlan.tasks.filter((task) => task.status === "completed").length;
    const progress = total ? Math.round((completed / total) * 100) : 0;
    return { total, completed, progress };
  }, [taskPlan]);

  const scrollToBottom = () => {
    if (!autoScrollRef.current) return;
    const el = historyRef.current;
    if (!el) return;
    el.scrollTop = el.scrollHeight;
  };

  const handleScroll = () => {
    const el = historyRef.current;
    if (!el) return;
    const threshold = 24;
    const nearBottom = el.scrollHeight - el.scrollTop - el.clientHeight < threshold;
    autoScrollRef.current = nearBottom;
  };

  useEffect(() => {
    const handle = setTimeout(scrollToBottom, 0);
    return () => clearTimeout(handle);
  }, [messages, loading, error]);

  const appendMessage = (role, content) => {
    setMessages((prev) => [...prev, { role, content }]);
  };

  const resetTaskPlan = (tasks) => {
    const normalized = (tasks || [])
      .map((task) => (typeof task === "string" ? task.trim() : ""))
      .filter(Boolean)
      .map((label) => ({ label, status: "pending" }));
    if (normalized.length === 0) {
      return;
    }
    setTaskPlan({ tasks: normalized });
  };

  const updateTaskProgress = (payload) => {
    if (!payload) return;
    setTaskPlan((prev) => {
      if (!prev || !Array.isArray(prev.tasks)) return prev;
      const tasks = prev.tasks.map((task) => ({ ...task }));
      const index =
        Number.isInteger(payload.index) && payload.index >= 0 && payload.index < tasks.length
          ? payload.index
          : -1;
      if (index >= 0) {
        tasks[index].status = payload.status || tasks[index].status;
        return { tasks };
      }
      if (payload.label) {
        const match = tasks.findIndex((task) => task.label === payload.label);
        if (match >= 0) {
          tasks[match].status = payload.status || tasks[match].status;
          return { tasks };
        }
      }
      return prev;
    });
  };

  const sendMessage = async (overrideText) => {
    const userText = (overrideText ?? input).trim();
    if (!userText || loading) return;
    appendMessage("user", userText);
    setInput("");
    setLoading(true);
    setError("");
    setPendingConfirm(false);
    autoScrollRef.current = true;
    setMessages((prev) => prev.slice(-80));
    // Respect user scroll; don't force auto-scroll on every message.
    let sawEvent = false;
    let rawSeen = false;
    let rawCombined = "";

    try {
      const res = await fetch(`${endpoint}/chat`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ message: userText, session_id: sessionId }),
      });
      if (!res.ok || !res.body) {
        throw new Error(`AI endpoint error (${res.status})`);
      }
      if (!res.body || !res.body.getReader) {
        const text = await res.text();
        if (text.trim()) {
          rawSeen = true;
          rawCombined = text;
          const lines = text.trim().split("\n");
          for (const line of lines) {
            try {
              const event = JSON.parse(line);
              sawEvent = true;
              if (event.type === "final") appendMessage("ai", event.content);
              if (event.type === "error") appendMessage("error", event.content);
            } catch {
              appendMessage("error", text.trim());
            }
          }
        }
      } else {
        const reader = res.body.getReader();
        const decoder = new TextDecoder();
        let buffer = "";

        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          if (value && value.length) rawSeen = true;
          const chunkText = decoder.decode(value, { stream: true });
          rawCombined += chunkText;
          buffer += chunkText;
          const parsed = parseNdjsonChunk(buffer);
          buffer = parsed.remaining || "";
          for (const event of parsed.events) {
            sawEvent = true;
            if (event.type === "tool_result") {
               let output = event.content;
               try {
                  const parsed = JSON.parse(output);
                  if (parsed?.error === "CONFIRMATION_REQUIRED") {
                    setPendingConfirm(true);
                    continue;
                  }
                  if (parsed.ok === false && parsed.error) {
                    // Keep backend details hidden; AI will summarize.
                    continue;
                  }
                  // For successful tool results, keep UI clean (AI will summarize).
                  continue;
               } catch {}
            } else if (event.type === "task_plan") {
              const tasks = Array.isArray(event.tasks) ? event.tasks : [];
              resetTaskPlan(tasks);
            } else if (event.type === "task_progress") {
              updateTaskProgress(event);
            } else if (event.type === "final") {
              appendMessage("ai", event.content);
            } else if (event.type === "error") {
              const raw = String(event.content || "");
              const sanitized =
                /context\\s+\"?.*\"?\\s+does not exist|kubeconfig|unable to connect to the server|x509/i.test(raw)
                  ? "I couldn’t reach the store environment. Please try again in a moment."
                  : raw;
              appendMessage("error", sanitized);
            }
          }
        }
        if (buffer.trim()) {
          try {
            const event = JSON.parse(buffer.trim());
            sawEvent = true;
            if (event.type === "final") appendMessage("ai", event.content);
            if (event.type === "error") appendMessage("error", event.content);
            if (event.type === "task_plan") {
              const tasks = Array.isArray(event.tasks) ? event.tasks : [];
              resetTaskPlan(tasks);
            }
            if (event.type === "task_progress") {
              updateTaskProgress(event);
            }
          } catch {
            // ignore parse errors
          }
        }
      }
      if (!sawEvent) {
        if (rawSeen) {
          const fallback = parseNdjsonFallback(rawCombined);
          if (fallback.length) {
            for (const event of fallback) {
              if (event.type === "final") appendMessage("ai", event.content);
              if (event.type === "error") appendMessage("error", event.content);
              if (event.type === "task_plan") {
                const tasks = Array.isArray(event.tasks) ? event.tasks : [];
                resetTaskPlan(tasks);
              }
              if (event.type === "task_progress") {
                updateTaskProgress(event);
              }
              if (event.type === "tool_result") {
                try {
                  const parsed = JSON.parse(event.content);
                  if (parsed?.error === "CONFIRMATION_REQUIRED") {
                    setPendingConfirm(true);
                  } else if (parsed?.note) {
                    // Let the agent summarize tool notes for consistency.
                  } else if (parsed?.error) {
                    // Hide backend errors; the agent will summarize.
                  }
                } catch {
                  // ignore
                }
              }
            }
          } else {
            const snippet = rawCombined.trim().slice(0, 280);
            appendMessage("error", `AI returned an unexpected response format. ${snippet}`);
          }
        } else {
          appendMessage("error", "No response from AI server. Check ai-orchestrator.log.");
        }
      }
    } catch (err) {
      setError(err?.message || "Failed to reach AI orchestrator.");
    } finally {
      setLoading(false);
    }
  };

  return (
    <section className="panel ai-chat">
      <h2>Urumi AI Orchestrator</h2>
      <p className="panel__subtitle">LangGraph agent for WooCommerce operations</p>

      <div className="ai-chat__history" ref={historyRef} onScroll={handleScroll}>
        {taskPlan && taskStats.total > 0 && (
          <div className="ai-chat__tasks">
            <div className="ai-chat__tasks-header">
              <span>Task Progress</span>
              <span>
                {taskStats.completed}/{taskStats.total} completed
              </span>
            </div>
            <div className="ai-chat__tasks-bar">
              <div
                className="ai-chat__tasks-bar-fill"
                style={{ width: `${taskStats.progress}%` }}
              />
            </div>
            <div className="ai-chat__tasks-list">
              {taskPlan.tasks.map((task, idx) => (
                <div key={`task-${idx}`} className={`ai-chat__task ai-chat__task--${task.status}`}>
                  <span className="ai-chat__task-dot" />
                  <span className="ai-chat__task-text">{task.label}</span>
                </div>
              ))}
            </div>
          </div>
        )}
        {messages.length === 0 && <div className="ai-chat__placeholder">Ask a command…</div>}
        {messages.map((msg, idx) => (
          <div key={`${msg.role}-${idx}`} className={`ai-chat__message ai-chat__message--${msg.role}`}>
            <span className="ai-chat__role">{msg.role}</span>
            <div className="ai-chat__content">{renderMarkdownBlocks(msg.content)}</div>
          </div>
        ))}
        {loading && <div className="ai-chat__status">Thinking…</div>}
        {error && <div className="ai-chat__error">{error}</div>}
        <div ref={endRef} />
      </div>

      <div className="ai-chat__input">
        <input
          value={input}
          onChange={(e) => setInput(e.target.value)}
          placeholder='e.g. "Refund order #5 and verify it"'
          onKeyDown={(e) => e.key === "Enter" && sendMessage()}
        />
        <button type="button" onClick={() => sendMessage()} disabled={!canSend}>
          Send
        </button>
        {pendingConfirm && (
          <button
            type="button"
            onClick={() => {
              sendMessage("confirm");
            }}
            className="ai-chat__confirm"
          >
            Confirm
          </button>
        )}
      </div>
    </section>
  );
}
