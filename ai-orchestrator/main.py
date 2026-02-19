#!/usr/bin/env python3
"""
FastAPI server for LangGraph-based AI Orchestrator.
POST /chat streams intermediate steps and final response as NDJSON.
"""

from __future__ import annotations
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import StreamingResponse
from langchain_core.messages import AIMessage, HumanMessage, ToolMessage
from pydantic import BaseModel, Field
from graph import build_graph
import os
import json
import uuid
import re
from dotenv import load_dotenv

load_dotenv()

APP = FastAPI(title="Urumi AI Orchestrator (LangGraph)", version="0.2.0")

# Allow dashboard to call the AI service
APP.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

GRAPH = build_graph()
SESSIONS: dict[str, list] = {}
SESSION_META: dict[str, dict] = {}
MAX_SESSION_MESSAGES = int(os.getenv("AI_SESSION_MAX", "60"))


def _session_meta(session_key: str) -> dict:
    meta = SESSION_META.get(session_key)
    if meta is None:
        meta = {
            "tasks": [],
            "statuses": [],
            "active_index": None,
            "completed": 0,
        }
        SESSION_META[session_key] = meta
    return meta


def _set_task_plan(meta: dict, tasks: list[str]) -> None:
    safe_tasks = [str(t).strip() for t in tasks if str(t).strip()]
    meta["tasks"] = safe_tasks
    meta["statuses"] = ["pending" for _ in safe_tasks]
    meta["active_index"] = None
    meta["completed"] = 0


def _extract_tasks_from_content(text: str) -> list[str]:
    if not text:
        return []
    lines = [line.strip() for line in str(text).splitlines()]
    tasks = []
    in_list = False
    for line in lines:
        if not line:
            if in_list:
                break
            continue
        if line.lower().startswith("step-by-step") or line.lower().startswith("step by step"):
            in_list = True
            continue
        if line.lower().startswith("to-do") or line.lower().startswith("todo"):
            in_list = True
            continue
        if re.match(r"^\\d+\\.", line):
            in_list = True
            tasks.append(re.sub(r"^\\d+\\.\\s*", "", line))
            continue
        if line.startswith("- "):
            if in_list or len(tasks) > 0:
                in_list = True
                tasks.append(line[2:].strip())
                continue
        if in_list:
            break
    return [t for t in tasks if t]


def _emit_task_plan_event(meta: dict) -> dict | None:
    tasks = meta.get("tasks") or []
    if not tasks:
        return None
    return {"type": "task_plan", "tasks": tasks}


def _emit_task_progress_event(meta: dict, index: int, status: str) -> dict | None:
    tasks = meta.get("tasks") or []
    if not tasks:
        return None
    total = len(tasks)
    if index < 0 or index >= total:
        return None
    statuses = meta.get("statuses") or []
    if len(statuses) != total:
        statuses = ["pending" for _ in tasks]
        meta["statuses"] = statuses
    statuses[index] = status
    completed = sum(1 for s in statuses if s == "completed")
    meta["completed"] = completed
    progress = int(round((completed / total) * 100)) if total else 0
    return {
        "type": "task_progress",
        "index": index,
        "status": status,
        "progress": progress,
        "completed": completed,
        "total": total,
    }


def _next_pending_task(meta: dict) -> int | None:
    tasks = meta.get("tasks") or []
    statuses = meta.get("statuses") or []
    if not tasks:
        return None
    if len(statuses) != len(tasks):
        statuses = ["pending" for _ in tasks]
        meta["statuses"] = statuses
    for idx, status in enumerate(statuses):
        if status == "pending":
            return idx
    return None


def _is_mutating_tool_call(call: dict) -> bool:
    if not isinstance(call, dict):
        return False
    name = str(call.get("name") or "").lower()
    
    # Dynamic MCP tools are named prefix_toolname (e.g., woo_create_product)
    # We consider it a mutation if the core tool name starts with a write prefix
    prefixes = ["create", "update", "delete", "send", "import", "set", "flush", "activate"]
    return any(f"_{p}_" in f"_{name}_" or name.split('_')[-1].startswith(p) for p in prefixes)


class ChatRequest(BaseModel):
    message: str = Field(..., min_length=3)
    session_id: str | None = None


def _ndjson_line(payload: dict) -> str:
    return json.dumps(payload) + "\\n"

def _trim_messages(messages: list) -> list:
    if len(messages) <= MAX_SESSION_MESSAGES:
        return messages
    return messages[-MAX_SESSION_MESSAGES:]


def _stream_events(user_input: str, session_id: str | None):
    try:
        print(f"DEBUG: Starting stream for input: {user_input}", flush=True)
        session_key = session_id or str(uuid.uuid4())
        history = SESSIONS.get(session_key, [])
        meta = _session_meta(session_key)
        state = {"messages": history + [HumanMessage(content=user_input)]}
        last_messages = state["messages"]
        # LangGraph "values" mode emits the full state after each node execution.
        # We look at the last message to determine what just happened.
        for event in GRAPH.stream(
            state,
            stream_mode="values",
            config={"recursion_limit": 20},
        ):
            print(f"DEBUG: Received event keys: {list(event.keys())}", flush=True)
            messages = event.get("messages", [])
            if not messages:
                print("DEBUG: No messages in event", flush=True)
                continue
            last_messages = messages
            
            last = messages[-1]
            print(f"DEBUG: Last message type: {type(last)}", flush=True)
            
            if isinstance(last, ToolMessage):
                # A tool just finished executing
                payload = {
                    "type": "tool_result",
                    "name": last.name,
                    "content": last.content,
                }
                print(f"DEBUG: Yielding tool_result: {payload}", flush=True)
                yield _ndjson_line(payload)

                # Update task progress for mutating tool calls.
                try:
                    parsed = json.loads(last.content)
                except Exception:
                    parsed = None
                if isinstance(parsed, dict):
                    if meta.get("tasks"):
                        idx = meta.get("active_index")
                        if idx is not None:
                            status = "completed" if parsed.get("ok") is not False else "failed"
                            event = _emit_task_progress_event(meta, idx, status)
                            if event:
                                yield _ndjson_line(event)
                            meta["active_index"] = None
            elif isinstance(last, AIMessage):
                if (last.content or "").strip() and not meta.get("tasks"):
                    extracted = _extract_tasks_from_content(last.content or "")
                    if extracted:
                        _set_task_plan(meta, extracted)
                        plan_event = _emit_task_plan_event(meta)
                        if plan_event:
                            yield _ndjson_line(plan_event)
                # The LLM just spoke
                if last.tool_calls:
                    # It wants to call a tool
                    payload = {
                        "type": "tool_call",
                        "content": [
                            {
                                "name": tc.get("name"),
                                "args": tc.get("args") or tc.get("arguments"),
                            }
                            for tc in last.tool_calls
                        ],
                    }
                    print(f"DEBUG: Yielding tool_call: {payload}", flush=True)
                    yield _ndjson_line(payload)
                    if meta.get("tasks"):
                        for call in payload.get("content") or []:
                            if _is_mutating_tool_call(call):
                                idx = meta.get("active_index")
                                if idx is None:
                                    idx = _next_pending_task(meta)
                                if idx is not None:
                                    meta["active_index"] = idx
                                    event = _emit_task_progress_event(meta, idx, "in_progress")
                                    if event:
                                        yield _ndjson_line(event)
                                break
                else:
                    # Final response (or clarification question)
                    payload = {"type": "final", "content": last.content}
                    print(f"DEBUG: Yielding final: {payload}", flush=True)
                    yield _ndjson_line(payload)
        SESSIONS[session_key] = _trim_messages(last_messages)
    except Exception as exc:
        print(f"DEBUG: Exception in stream: {exc}", flush=True)
        yield _ndjson_line({"type": "error", "content": str(exc)})


@APP.get("/healthz")
def healthz():
    return {"status": "ok"}


@APP.post("/chat")
def chat(req: ChatRequest):
    if not req.message.strip():
        raise HTTPException(status_code=400, detail="message is required")
    return StreamingResponse(
        _stream_events(req.message, req.session_id),
        media_type="application/x-ndjson",
    )
