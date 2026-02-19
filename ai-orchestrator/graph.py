from __future__ import annotations

import json
import os
import re
import requests
import logging
import sys
import asyncio
from typing import Annotated, TypedDict, Literal

from langchain_openai import ChatOpenAI
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage, ToolMessage
from langgraph.graph import END, StateGraph, START
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode

from tools import get_store_pod_info
from tool_registry import ALL_TOOLS

# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


SYSTEM_PROMPT = """
You are a deterministic store orchestration agent.

Rules:
- Always inspect before mutating.
- Never hallucinate tool arguments.
- Use exact tool names.
- If store not specified and multiple exist, request clarification.
"""

class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]

def get_model(store_name: str | None = None):
    endpoint = os.getenv("AZURE_OPENAI_ENDPOINT", "")
    api_key = os.getenv("AZURE_OPENAI_API_KEY", "")
    deployment = os.getenv("AZURE_OPENAI_DEPLOYMENT", "")

    model = ChatOpenAI(
        base_url=endpoint,
        api_key=api_key,
        model=deployment,
        temperature=1,
    )

    return model.bind_tools(ALL_TOOLS)

STORE_RE = re.compile(r"\bstore\s+([a-z0-9-]+)\b", re.I)
STORE_IN_RE = re.compile(r"\bin\s+([a-z0-9-]+)\s+store\b", re.I)

def _infer_store_from_messages(messages: list[BaseMessage]) -> str | None:
    # Only infer from the most recent human message to avoid "self-inference" from agent questions
    for msg in reversed(messages):
        if not isinstance(msg, HumanMessage):
            continue
        text = (msg.content or "").lower()
        text = re.sub(r"[\\*`_]", "", text)
        m = STORE_RE.search(text)
        if m:
            return m.group(1).lower()
        m = STORE_IN_RE.search(text)
        if m:
            return m.group(1).lower()
    return None

async def agent_node(state: AgentState):
    messages = state["messages"]
    
    # Fetch available stores to provide context to the LLM
    api = os.getenv("ORCH_API_BASE", "http://localhost:8080").rstrip("/")
    stores_context = ""
    try:
        resp = requests.get(f"{api}/api/stores", timeout=5)
        if resp.status_code == 200:
            stores = resp.json()
            if isinstance(stores, list) and stores:
                store_names = [s.get("name") or s.get("id") for s in stores]
                stores_context = f"\n\nCURRENT SYSTEM STATE: The following stores are available: {', '.join(store_names)}. "
                if len(stores) == 1:
                    stores_context += f"Automatically use store '{store_names[0]}' for all operations unless the user explicitly names a different one."
                else:
                    stores_context += "You must identify which store the user is referring to. If it is ambiguous, ask for clarification from the available list."
    except Exception as e:
        logger.warning(f"Could not fetch stores for context: {e}")

    # Ensure the first message is a SystemMessage with the latest context
    if not messages or not isinstance(messages[0], SystemMessage):
        messages = [SystemMessage(content=SYSTEM_PROMPT + stores_context)] + messages
    else:
        messages[0] = SystemMessage(content=SYSTEM_PROMPT + stores_context)
    
    inferred = _infer_store_from_messages(messages)
    if inferred:
        hint = SystemMessage(content=f"Current focus: Store '{inferred}'. Please ensure all tool calls use this store name.")
        # Remove any existing hints to avoid clutter
        messages = [messages[0], hint] + [m for m in messages[1:] if not (isinstance(m, SystemMessage) and "Current focus" in str(m.content))]

    model = get_model(inferred)
    response = await model.ainvoke(messages)
    if response.tool_calls:
        await asyncio.sleep(0.5)
    return {"messages": [response]}

def should_continue(state: AgentState) -> Literal["tools", "__end__"]:
    messages = state["messages"]
    last_message = messages[-1]
    if last_message.tool_calls:
        return "tools"
    return END

def build_graph():
    workflow = StateGraph(AgentState)
    workflow.add_node("agent", agent_node)
    
    # Lazy ToolNode that fetches tools on each call if needed
    workflow.add_node("tools", ToolNode(ALL_TOOLS))
        
    workflow.add_edge(START, "agent")
    workflow.add_conditional_edges("agent", should_continue)
    workflow.add_edge("tools", "agent")
    return workflow.compile()
