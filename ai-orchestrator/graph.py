from __future__ import annotations

import json
import os
import re
import requests
import logging
import sys
from typing import Annotated, TypedDict, Literal

from langchain_openai import ChatOpenAI
from langchain_core.messages import AIMessage, BaseMessage, HumanMessage, SystemMessage, ToolMessage
from langgraph.graph import END, StateGraph, START
from langgraph.graph.message import add_messages
from langgraph.prebuilt import ToolNode

from tools import get_store_api_keys, get_store_pod_info
from mcp_client import McpToolBridge


# Configure logging
logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Global cache for discovered tools
_DYNAMIC_TOOLS_CACHE = {}

def get_dynamic_tools(store_name: str | None = None):
    """Discover tools from MCP servers. Auto-selects if only one store exists or if store_name is provided."""
    global _DYNAMIC_TOOLS_CACHE
    
    if store_name is None:
        store_name = "nike"
    
    store_key = store_name.lower() if store_name else "default"
    if store_key in _DYNAMIC_TOOLS_CACHE:
        return _DYNAMIC_TOOLS_CACHE[store_key]
        
    logger.info(f"Initializing dynamic MCP tool discovery for store: {store_name}...")
    api = os.getenv("ORCH_API_BASE", "http://localhost:8080").rstrip("/")
    try:
        resp = requests.get(f"{api}/api/stores", timeout=5)
        if resp.status_code != 200:
            logger.warning(f"/api/stores returned {resp.status_code}: {resp.text}")
            return []
        
        stores = resp.json()
        if not isinstance(stores, list):
            logger.warning(f"/api/stores did not return a list: {stores}")
            stores = []

        selected_store = None
        if store_name:
            # Match provided store name
            for s in stores:
                if (s.get("name") or "").lower() == store_name.lower() or (s.get("id") or "").lower() == store_name.lower():
                    selected_store = s
                    break
        elif len(stores) == 1:
            # Auto-select single store
            selected_store = stores[0]
        
        if not selected_store:
            # If we can't find the store, we can't discover tools
            return []

        # We have a selected store
        target_store_name = (selected_store.get("name") or selected_store.get("id")).lower()
        
        # Internal tools use kubectl exec, so we don't need valid API keys.
        # This prevents the destructive delete/create password loop.
        try:
            get_store_pod_info(target_store_name) # Ensure pod is reachable
        except Exception as e:
            logger.warning(f"Store {target_store_name} pod not reachable: {e}")
            return []

        dummy_url = f"http://{target_store_name}.internal"
        dummy_ck = "internal"
        dummy_cs = "internal"
        
        # WooCommerce MCP Tools (Internal)
        woo_server_path = os.path.join(os.path.dirname(__file__), "woocommerce_mcp_server.py")
        woo_bridge = McpToolBridge("woo", f"{sys.executable} {woo_server_path}", dummy_url, dummy_ck, dummy_cs)
        woo_tools = woo_bridge.get_tools()
        
        # Elementor MCP Tools (Internal)
        ele_server_path = os.path.join(os.path.dirname(__file__), "elementor_mcp_server.py")
        ele_bridge = McpToolBridge("elementor", f"{sys.executable} {ele_server_path}", dummy_url, dummy_ck, dummy_cs)
        ele_tools = ele_bridge.get_tools()
        
        # Popup Maker MCP Tools (Internal)
        popup_server_path = os.path.join(os.path.dirname(__file__), "popup_mcp_server.py")
        popup_bridge = McpToolBridge("popup", f"{sys.executable} {popup_server_path}", dummy_url, dummy_ck, dummy_cs)
        popup_tools = popup_bridge.get_tools()
        
        # Urumi Suite MCP Tools (Catcher, MailPoet, Urumi Tools)
        suite_server_path = os.path.join(os.path.dirname(__file__), "urumi_suite_mcp_server.py")
        suite_bridge = McpToolBridge("suite", f"{sys.executable} {suite_server_path}", dummy_url, dummy_ck, dummy_cs)
        suite_tools = suite_bridge.get_tools()
        
        combined_tools = woo_tools + ele_tools + popup_tools + suite_tools
        if combined_tools:
            _DYNAMIC_TOOLS_CACHE[store_key] = combined_tools
            
        return combined_tools

    except Exception as e:
        logger.error(f"Failed to discover dynamic MCP tools: {e}")
        return []

SYSTEM_PROMPT = """You are the Urumi Store Architect. You manage stores via official Model Context Protocol (MCP) tools.

### Safe Execution Protocol
1. **READ FIRST**: Always list or get a resource to verify its state before modifying it.
2. **EXECUTE**: Run the specific MCP tool required.
3. **VERIFY**: Check the status again to confirm success.

### Rules
- Execute requests immediately without confirmations.
- Be professional, efficient, and helpful.
- Never mention internal technical details (kubectl, proxies, etc.) to end users.
- Use Markdown for lists and emphasis.
- If multiple stores exist and the user hasn't specified one, ask them to clarify which store they want to manage.
"""

class AgentState(TypedDict):
    messages: Annotated[list[BaseMessage], add_messages]

def get_model(store_name: str | None = None):
    endpoint = os.getenv("AZURE_OPENAI_ENDPOINT", "")
    api_key = os.getenv("AZURE_OPENAI_API_KEY", "")
    deployment = os.getenv("AZURE_OPENAI_DEPLOYMENT", "")

    if not endpoint or not api_key or not deployment:
        raise RuntimeError("Missing Azure OpenAI configuration.")

    model = ChatOpenAI(
        base_url=endpoint,
        api_key=api_key,
        model=deployment,
        temperature=1.0,
    )
    
    tools = get_dynamic_tools(store_name)
    if tools:
        return model.bind_tools(tools)
    return model

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

def agent_node(state: AgentState):
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
    response = model.invoke(messages)
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
    def dynamic_tool_node(state):
        messages = state["messages"]
        inferred = _infer_store_from_messages(messages)
        tools = get_dynamic_tools(inferred)
        return ToolNode(tools).invoke(state)

    workflow.add_node("tools", dynamic_tool_node)
        
    workflow.add_edge(START, "agent")
    workflow.add_conditional_edges("agent", should_continue)
    workflow.add_edge("tools", "agent")
    return workflow.compile()
