import json
import os
import sys
import mcp.types as types
from base_mcp_server import BaseMcpServer

# Add parent directory to path for tools import if needed
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from tools import run_wp_cli_command

# Initialize Server
mcp = BaseMcpServer("urumi-suite-mcp", "0.1.0")

# --- Handlers ---

async def list_tools() -> list[types.Tool]:
    return [
        # --- Urumi Campaign Tools ---
        types.Tool(
            name="urumi_create_banner",
            description="Create a store-wide announcement banner",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "headline": {"type": "string"},
                    "subheadline": {"type": "string"},
                    "coupon": {"type": "string"},
                    "cta_text": {"type": "string", "default": "Shop Now"},
                    "enabled": {"type": "boolean", "default": True}
                },
                "required": ["store_name", "headline"]
            }
        ),
        # --- WP Mail Catcher (Logging) ---
        types.Tool(
            name="catcher_list_emails",
            description="List recently logged/captured outgoing emails",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "limit": {"type": "integer", "default": 5}
                },
                "required": ["store_name"]
            }
        ),
        # --- MailPoet ---
        types.Tool(
            name="mailpoet_list_subscribers",
            description="List MailPoet subscribers",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "limit": {"type": "integer", "default": 10}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="mailpoet_create_campaign",
            description="Create a new MailPoet email campaign",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "subject": {"type": "string"},
                    "body": {"type": "string", "description": "HTML content of the email"}
                },
                "required": ["store_name", "subject", "body"]
            }
        )
    ]

async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    store_name = arguments.get("store_name")
    
    # Use helper from BaseMcpServer
    ns, pod = mcp.get_store_info(store_name)
    
    # --- Urumi ---
    if name == "urumi_create_banner":
        headline = arguments.get("headline")
        sub = arguments.get("subheadline", "")
        coupon = arguments.get("coupon", "")
        cta = arguments.get("cta_text", "Shop Now")
        enabled = "true" if arguments.get("enabled", True) else "false"
        
        args = [
            "urumi", "banner", "create",
            f"--headline={headline}", f"--subheadline={sub}", f"--coupon={coupon}",
            f"--cta_text={cta}", f"--enabled={enabled}"
        ]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    # --- Mail Catcher ---
    elif name == "catcher_list_emails":
        limit = arguments.get("limit", 5)
        # Attempt to query the common mail logging table
        sql = f"SELECT * FROM wp_mail_logging ORDER BY id DESC LIMIT {limit}"
        output = run_wp_cli_command(ns, pod, ["db", "query", sql, "--format=json"])
        
        if "Error" in output:
             sql = f"SELECT * FROM wp_output_log ORDER BY id DESC LIMIT {limit}"
             output = run_wp_cli_command(ns, pod, ["db", "query", sql, "--format=json"])
        return [types.TextContent(type="text", text=output)]

    # --- MailPoet ---
    elif name == "mailpoet_list_subscribers":
        php_code = """
        try {
            if (!class_exists('\\MailPoet\\API\\API')) {
                echo json_encode(['ok' => false, 'error' => 'MailPoet API not found']);
                exit;
            }
            $api = \\MailPoet\\API\\API::MP('v1');
            echo json_encode(['ok' => true, 'subscribers' => $api->getSubscriberCount()]);
        } catch (\\Exception $e) {
            echo json_encode(['ok' => false, 'error' => $e->getMessage()]);
        }
        """
        output = run_wp_cli_command(ns, pod, ["eval", php_code])
        return [types.TextContent(type="text", text=output)]

    elif name == "mailpoet_create_campaign":
        subject = arguments.get("subject")
        body = arguments.get("body")
        php_code = f"""
        try {{
            if (!class_exists('\\MailPoet\\API\\API')) {{
                echo json_encode(['ok' => false, 'error' => 'MailPoet API not found']);
                exit;
            }}
            $api = \\MailPoet\\API\\API::MP('v1');
            $newsletter = $api->saveNewsletter([
                'type' => 'standard',
                'subject' => {json.dumps(subject)},
                'body' => ['content' => {json.dumps(body)}]
            ]);
            echo json_encode(['ok' => true, 'id' => $newsletter['id'], 'message' => 'Campaign created']);
        }} catch (\\Exception $e) {{
            echo json_encode(['ok' => false, 'error' => $e->getMessage()]);
        }}
        """
        output = run_wp_cli_command(ns, pod, ["eval", php_code])
        return [types.TextContent(type="text", text=output)]
    
    raise ValueError(f"Unknown tool: {name}")

if __name__ == "__main__":
    mcp.register_handlers(list_tools, call_tool)
    mcp.serve()
