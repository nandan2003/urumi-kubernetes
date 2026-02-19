import json
import os
import sys
import mcp.types as types
from base_mcp_server import BaseMcpServer

# Add parent directory to path for tools import if needed
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
from tools import run_wp_cli_command

# Initialize Server
mcp = BaseMcpServer("woocommerce-mcp", "1.1.0")

# --- Handlers ---

async def list_tools() -> list[types.Tool]:
    return [
        # --- PRODUCTS ---
        types.Tool(
            name="list_products",
            description="List WooCommerce products with filtering and pagination",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "per_page": {"type": "integer", "default": 10},
                    "page": {"type": "integer", "default": 1},
                    "status": {"type": "string", "enum": ["publish", "draft", "pending", "private", "any"]}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="get_product",
            description="Get details of a specific product by ID",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"}
                },
                "required": ["store_name", "id"]
            }
        ),
        types.Tool(
            name="create_product",
            description="Create a new product",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "name": {"type": "string"},
                    "type": {"type": "string", "enum": ["simple", "variable", "grouped", "external"], "default": "simple"},
                    "regular_price": {"type": "string"},
                    "description": {"type": "string"},
                    "short_description": {"type": "string"},
                    "sku": {"type": "string"},
                    "status": {"type": "string", "enum": ["publish", "draft"], "default": "publish"}
                },
                "required": ["store_name", "name", "regular_price"]
            }
        ),
        types.Tool(
            name="update_product",
            description="Update an existing product",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"},
                    "name": {"type": "string"},
                    "regular_price": {"type": "string"},
                    "sale_price": {"type": "string"},
                    "status": {"type": "string", "enum": ["publish", "draft"]},
                    "stock_quantity": {"type": "integer"}
                },
                "required": ["store_name", "id"]
            }
        ),
        types.Tool(
            name="delete_product",
            description="Delete a product (permanently or to trash)",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"},
                    "force": {"type": "boolean", "default": False, "description": "True to bypass trash"}
                },
                "required": ["store_name", "id"]
            }
        ),

        # --- ORDERS ---
        types.Tool(
            name="list_orders",
            description="List WooCommerce orders with filtering",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "per_page": {"type": "integer", "default": 10},
                    "status": {"type": "string", "enum": ["pending", "processing", "on-hold", "completed", "cancelled", "refunded", "failed", "any"]}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="get_order",
            description="Get details of a specific order",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"}
                },
                "required": ["store_name", "id"]
            }
        ),
        types.Tool(
            name="update_order",
            description="Update order status or metadata",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"},
                    "status": {"type": "string", "enum": ["pending", "processing", "on-hold", "completed", "cancelled", "refunded", "failed"]},
                    "customer_note": {"type": "string"}
                },
                "required": ["store_name", "id"]
            }
        ),

        # --- COUPONS ---
        types.Tool(
            name="list_coupons",
            description="List all discount coupons",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="create_coupon",
            description="Create a discount coupon",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "code": {"type": "string"},
                    "amount": {"type": "string"},
                    "discount_type": {"type": "string", "enum": ["percent", "fixed_cart", "fixed_product"], "default": "percent"},
                    "description": {"type": "string"},
                    "individual_use": {"type": "boolean", "default": False},
                    "usage_limit": {"type": "integer"}
                },
                "required": ["store_name", "code", "amount"]
            }
        ),
        types.Tool(
            name="delete_coupon",
            description="Delete a coupon",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"}
                },
                "required": ["store_name", "id"]
            }
        ),

        # --- CUSTOMERS ---
        types.Tool(
            name="list_customers",
            description="List WooCommerce customers",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "per_page": {"type": "integer", "default": 10},
                    "role": {"type": "string", "default": "all"}
                },
                "required": ["store_name"]
            }
        ),
        types.Tool(
            name="get_customer",
            description="Get customer details by ID",
            inputSchema={
                "type": "object",
                "properties": {
                    "store_name": {"type": "string"},
                    "id": {"type": "integer"}
                },
                "required": ["store_name", "id"]
            }
        )
    ]

async def call_tool(name: str, arguments: dict) -> list[types.TextContent]:
    store_name = arguments.get("store_name")
    
    # Use helper from BaseMcpServer
    ns, pod = mcp.get_store_info(store_name)

    base_args = ["wc"]

    # --- PRODUCT HANDLERS ---
    if name == "list_products":
        limit = arguments.get("per_page", 10)
        page = arguments.get("page", 1)
        status = arguments.get("status", "any")
        args = base_args + ["product", "list", f"--per_page={limit}", f"--page={page}", f"--status={status}", "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "get_product":
        args = base_args + ["product", "get", str(arguments["id"]), "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "create_product":
        args = base_args + ["product", "create"]
        for key in ["name", "type", "regular_price", "description", "short_description", "sku", "status"]:
            if key in arguments: args.append(f"--{key}={arguments[key]}")
        args.append("--porcelain")
        
        output = run_wp_cli_command(ns, pod, args)
        if output.startswith("Error:"): return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        return [types.TextContent(type="text", text=json.dumps({"ok": True, "id": output.strip(), "message": "Product created"}))]

    elif name == "update_product":
        args = base_args + ["product", "update", str(arguments["id"])]
        for key in ["name", "regular_price", "sale_price", "status", "stock_quantity"]:
            if key in arguments: args.append(f"--{key}={arguments[key]}")
        
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "delete_product":
        args = base_args + ["product", "delete", str(arguments["id"])]
        if arguments.get("force"): args.append("--force")
        
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    # --- ORDER HANDLERS ---
    elif name == "list_orders":
        limit = arguments.get("per_page", 10)
        status = arguments.get("status", "any")
        args = base_args + ["shop_order", "list", f"--per_page={limit}", f"--status={status}", "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "get_order":
        args = base_args + ["shop_order", "get", str(arguments["id"]), "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "update_order":
        args = base_args + ["shop_order", "update", str(arguments["id"])]
        if "status" in arguments: args.append(f"--status={arguments['status']}")
        if "customer_note" in arguments: args.append(f"--customer_note={arguments['customer_note']}")
        
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    # --- COUPON HANDLERS ---
    elif name == "list_coupons":
        args = base_args + ["shop_coupon", "list", "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "create_coupon":
        args = base_args + ["shop_coupon", "create"]
        for key in ["code", "amount", "discount_type", "description", "usage_limit"]:
            if key in arguments: args.append(f"--{key}={arguments[key]}")
        if arguments.get("individual_use"): args.append("--individual_use=true")
        args.append("--porcelain")
        
        output = run_wp_cli_command(ns, pod, args)
        if output.startswith("Error:"): return [types.TextContent(type="text", text=json.dumps({"ok": False, "error": output}))]
        return [types.TextContent(type="text", text=json.dumps({"ok": True, "id": output.strip(), "message": "Coupon created"}))]

    elif name == "delete_coupon":
        args = base_args + ["shop_coupon", "delete", str(arguments["id"]), "--force"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    # --- CUSTOMER HANDLERS ---
    elif name == "list_customers":
        limit = arguments.get("per_page", 10)
        role = arguments.get("role", "all")
        args = base_args + ["customer", "list", f"--per_page={limit}", f"--role={role}", "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    elif name == "get_customer":
        args = base_args + ["customer", "get", str(arguments["id"]), "--format=json"]
        output = run_wp_cli_command(ns, pod, args)
        return [types.TextContent(type="text", text=output)]

    raise ValueError(f"Unknown tool: {name}")

if __name__ == "__main__":
    mcp.register_handlers(list_tools, call_tool)
    mcp.serve()
