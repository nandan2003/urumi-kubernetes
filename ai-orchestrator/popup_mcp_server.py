import json
import os
import sys
import mcp.types as types
from base_mcp_server import BaseMcpServer

# Add parent directory to path for tools import if needed
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from tools import run_wp_cli_command, _kubectl

# Initialize Server
mcp = BaseMcpServer("popup-maker-mcp", "1.0.0")

# --- Handlers ---

async def list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="list_popups",
            description="List all Popup Maker popups",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="create_popup",
            description="Create a new popup",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "title": {"type": "string", "description": "Popup title"},
                    "content": {"type": "string", "description": "Popup content (HTML supported)"},
                    "status": {"type": "string", "enum": ["publish", "draft"], "default": "publish"}
                },
                "required": ["store_name", "title", "content"]
            }
        ),
        types.Tool(
            name="update_popup",
            description="Update an existing popup",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "popup_id": {"type": "integer"},
                    "title": {"type": "string"},
                    "content": {"type": "string"},
                    "status": {"type": "string", "enum": ["publish", "draft"]}
                },
                "required": ["store_name", "popup_id"]
            }
        ),
        types.Tool(
            name="delete_popup",
            description="Delete a popup",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "popup_id": {"type": "integer"}
                },
                "required": ["store_name", "popup_id"]
            }
        ),
        types.Tool(
            name="set_popup_settings",
            description="Set specific Popup Maker settings (triggers, cookies, display)",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "popup_id": {"type": "integer"},
                    "settings": {
                        "type": "object",
                        "description": "JSON object of settings. Common keys: 'triggers' (array), 'cookies' (array), 'display' (object). Example: {'triggers': [{'type': 'auto_open', 'settings': {'delay': 500}}]}"
                    }
                },
                "required": ["store_name", "popup_id", "settings"]
            }
        )
    ]

async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    store_name = arguments.get("store_name")
    
    # Use helper from BaseMcpServer
    ns, pod = mcp.get_store_info(store_name)

    if name == "list_popups":
        output = run_wp_cli_command(ns, pod, ["post", "list", "--post_type=popup", "--format=json"])
        
        # Check for error in output before parsing
        if output.startswith("Error:"):
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        
        try:
            popups = json.loads(output)
            return [types.TextContent(type="text", text=json.dumps({"ok": True, "data": popups}))]
        except json.JSONDecodeError:
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": "Invalid JSON response from WP-CLI", "raw": output}))]

    elif name == "create_popup":
        title = arguments.get("title")
        content = arguments.get("content")
        status = arguments.get("status", "publish")
        
        create_args = [
            "post", "create", 
            f"--post_type=popup", 
            f"--post_title={title}", 
            f"--post_content={content}", 
            f"--post_status={status}",
            "--porcelain"
        ]
        output = run_wp_cli_command(ns, pod, create_args)
        
        if output.startswith("Error:"):
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        
        try:
            popup_id = int(output.strip())
            # Set default settings
            default_settings = {
                "triggers": [{"type": "auto_open", "settings": {"delay": 500}}],
                "cookies": [],
                "conditions": []
            }
            # Update meta
            meta_args = [
                "post", "meta", "update", str(popup_id), 
                "_pum_popup_settings", json.dumps(default_settings)
            ]
            run_wp_cli_command(ns, pod, meta_args)
            
            return [types.TextContent(type="text", text=json.dumps({"ok": True, "data": {"id": popup_id, "message": "Popup created"}}))]
        except ValueError:
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": "Failed to parse popup ID", "raw": output}))]

    elif name == "update_popup":
        popup_id = arguments.get("popup_id")
        updates = []
        if "title" in arguments:
            updates.append(f"--post_title={arguments['title']}")
        if "content" in arguments:
            updates.append(f"--post_content={arguments['content']}")
        if "status" in arguments:
            updates.append(f"--post_status={arguments['status']}")
        
        if not updates:
            return [types.TextContent(type="text", text=json.dumps({"ok": True, "message": "No updates requested"}))]

        args = ["post", "update", str(popup_id)] + updates
        output = run_wp_cli_command(ns, pod, args)
        
        if output.startswith("Error:"):
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        
        return [types.TextContent(type="text", text=json.dumps({"ok": True, "data": {"id": popup_id, "message": "Popup updated"}}))]

    elif name == "delete_popup":
        popup_id = arguments.get("popup_id")
        output = run_wp_cli_command(ns, pod, ["post", "delete", str(popup_id), "--force"])
        
        if output.startswith("Error:"):
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        
        return [types.TextContent(type="text", text=json.dumps({"ok": True, "message": "Popup deleted"}))]

    elif name == "set_popup_settings":
        popup_id = arguments.get("popup_id")
        settings = arguments.get("settings")
        
        # Get existing
        current_raw = run_wp_cli_command(ns, pod, ["post", "meta", "get", str(popup_id), "_pum_popup_settings", "--format=json"])
        
        current_settings = {}
        if not current_raw.startswith("Error:"):
            try:
                current_settings = json.loads(current_raw)
            except:
                pass
        
        if isinstance(current_settings, dict):
            current_settings.update(settings)
        else:
            current_settings = settings

        output = run_wp_cli_command(ns, pod, ["post", "meta", "update", str(popup_id), "_pum_popup_settings", json.dumps(current_settings)])
        
        if output.startswith("Error:"):
             return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        
        return [types.TextContent(type="text", text=json.dumps({"ok": True, "message": "Settings updated"}))]

    raise ValueError(f"Unknown tool: {name}")

if __name__ == "__main__":
    mcp.register_handlers(list_tools, call_tool)
    mcp.serve()
