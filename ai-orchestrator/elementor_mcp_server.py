import json
import os
import sys
import mcp.types as types
from base_mcp_server import BaseMcpServer

# Add parent directory to path for tools import if needed (BaseMcpServer handles most)
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from tools import _kubectl, _wp_base_cmd

# Initialize Server
mcp = BaseMcpServer("elementor-mcp", "1.1.0")
logger = mcp.logger

# --- Allowlist Logic ---
_ALLOWLIST_CACHE = None

def _load_allowlist() -> dict:
    global _ALLOWLIST_CACHE
    if _ALLOWLIST_CACHE is not None:
        return _ALLOWLIST_CACHE
    try:
        path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "elementor-allowlist.json")
        with open(path, "r") as f:
            _ALLOWLIST_CACHE = json.load(f)
    except Exception as e:
        logger.error(f"Failed to load allowlist: {e}")
        _ALLOWLIST_CACHE = {}
    return _ALLOWLIST_CACHE

def _is_command_allowed(subcommand: str) -> bool:
    allowlist = _load_allowlist()
    cmd_spec = allowlist.get("elementor", {}).get("commands", {}).get(subcommand)
    if not cmd_spec:
        normalized = subcommand.replace("_", "-")
        cmd_spec = allowlist.get("elementor", {}).get("commands", {}).get(normalized)
    
    if not cmd_spec:
        return False
    return True

# --- Handlers ---

async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="flush_css",
            description="Flush Elementor CSS cache",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="replace_urls",
            description="Replace URLs in Elementor content (useful after migrations)",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "old_url": {"type": "string"},
                    "new_url": {"type": "string"}
                },
                "required": ["store_name", "old_url", "new_url"]
            }
        ),
        types.Tool(
            name="library_sync",
            description="Sync Elementor library with remote server",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="system_info",
            description="Get Elementor system info",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"}
                },
                "required": ["store_name"]
            }
        )
    ]

async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    store_name = arguments.get("store_name")
    
    # Use helper from BaseMcpServer
    ns, pod = mcp.get_store_info(store_name)

    base_cmd = ["-n", ns, "exec", pod, "--", *_wp_base_cmd(), "elementor"]
    common_flags = ["--allow-root", "--user=admin"]
    
    subcommand_map = {
        "flush_css": "flush-css",
        "replace_urls": "replace-urls",
        "library_sync": "library-sync",
        "system_info": "system-info"
    }
    
    elementor_cmd = subcommand_map.get(name)
    if not elementor_cmd:
        raise ValueError(f"Unknown tool: {name}")

    if not _is_command_allowed(elementor_cmd):
        return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": f"Command '{elementor_cmd}' is not allowed by policy."}))]

    if name == "flush_css":
        cmd = base_cmd + [elementor_cmd] + common_flags
        output = _kubectl(cmd)
        return [types.TextContent(type="text", text=output)]

    elif name == "replace_urls":
        cmd = base_cmd + [elementor_cmd, arguments["old_url"], arguments["new_url"]] + common_flags
        output = _kubectl(cmd)
        return [types.TextContent(type="text", text=output)]

    elif name == "library_sync":
        cmd = base_cmd + [elementor_cmd] + common_flags
        output = _kubectl(cmd)
        return [types.TextContent(type="text", text=output)]

    elif name == "system_info":
        cmd = base_cmd + [elementor_cmd] + common_flags
        output = _kubectl(cmd)
        return [types.TextContent(type="text", text=output)]

    raise ValueError(f"Unknown tool: {name}")

if __name__ == "__main__":
    mcp.register_handlers(list_tools, call_tool)
    mcp.serve()
