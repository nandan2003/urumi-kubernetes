# tool_registry.py

import json
from typing import Optional, Dict, Any
from pydantic import BaseModel, Field
from langchain_core.tools import StructuredTool
from tools import run_wp_cli_command, get_store_pod_info


# ============================================================
# COMMON
# ============================================================

def resolve_store(store_name: str):
    return get_store_pod_info(store_name)


# ============================================================
# PRODUCTS
# ============================================================

class ListProductsInput(BaseModel):
    store_name: str
    per_page: int = 10
    page: int = 1
    status: str = "any"

def list_products(store_name: str, per_page: int = 10, page: int = 1, status: str = "any"):
    ns, pod = resolve_store(store_name)
    args = [
        "wc", "product", "list",
        f"--per_page={per_page}",
        f"--page={page}",
        f"--status={status}",
        "--format=json"
    ]
    return run_wp_cli_command(ns, pod, args)


class GetProductInput(BaseModel):
    store_name: str
    id: int

def get_product(store_name: str, id: int):
    ns, pod = resolve_store(store_name)
    args = ["wc", "product", "get", str(id), "--format=json"]
    return run_wp_cli_command(ns, pod, args)


class CreateProductInput(BaseModel):
    store_name: str
    name: str
    regular_price: str
    type: str = "simple"
    description: Optional[str] = None
    short_description: Optional[str] = None
    sku: Optional[str] = None
    status: str = "publish"

def create_product(
    store_name: str,
    name: str,
    regular_price: str,
    type: str = "simple",
    description: Optional[str] = None,
    short_description: Optional[str] = None,
    sku: Optional[str] = None,
    status: str = "publish",
):
    ns, pod = resolve_store(store_name)

    args = ["wc", "product", "create"]

    for key, value in {
        "name": name,
        "type": type,
        "regular_price": regular_price,
        "description": description,
        "short_description": short_description,
        "sku": sku,
        "status": status,
    }.items():
        if value is not None:
            args.append(f"--{key}={value}")

    args.append("--porcelain")

    return run_wp_cli_command(ns, pod, args)



class UpdateProductInput(BaseModel):
    store_name: str
    id: int
    name: Optional[str] = None
    regular_price: Optional[str] = None
    sale_price: Optional[str] = None
    status: Optional[str] = None
    stock_quantity: Optional[int] = None

def update_product(**kwargs):
    ns, pod = resolve_store(kwargs["store_name"])
    args = ["wc", "product", "update", str(kwargs["id"])]

    for key in ["name", "regular_price", "sale_price", "status", "stock_quantity"]:
        if kwargs.get(key) is not None:
            args.append(f"--{key}={kwargs[key]}")

    return run_wp_cli_command(ns, pod, args)


class DeleteProductInput(BaseModel):
    store_name: str
    id: int
    force: bool = False

def delete_product(store_name: str, id: int, force: bool = False):
    ns, pod = resolve_store(store_name)
    args = ["wc", "product", "delete", str(id)]
    if force:
        args.append("--force")
    return run_wp_cli_command(ns, pod, args)


# ============================================================
# ORDERS
# ============================================================

class ListOrdersInput(BaseModel):
    store_name: str
    per_page: int = 10
    status: str = "any"

def list_orders(store_name: str, per_page: int = 10, status: str = "any"):
    ns, pod = resolve_store(store_name)
    args = [
        "wc", "shop_order", "list",
        f"--per_page={per_page}",
        f"--status={status}",
        "--format=json"
    ]
    return run_wp_cli_command(ns, pod, args)


class GetOrderInput(BaseModel):
    store_name: str
    id: int

def get_order(store_name: str, id: int):
    ns, pod = resolve_store(store_name)
    args = ["wc", "shop_order", "get", str(id), "--format=json"]
    return run_wp_cli_command(ns, pod, args)


class UpdateOrderInput(BaseModel):
    store_name: str
    id: int
    status: Optional[str] = None
    customer_note: Optional[str] = None

def update_order(**kwargs):
    ns, pod = resolve_store(kwargs["store_name"])
    args = ["wc", "shop_order", "update", str(kwargs["id"])]

    if kwargs.get("status"):
        args.append(f"--status={kwargs['status']}")
    if kwargs.get("customer_note"):
        args.append(f"--customer_note={kwargs['customer_note']}")

    return run_wp_cli_command(ns, pod, args)


# ============================================================
# COUPONS
# ============================================================

class ListCouponsInput(BaseModel):
    store_name: str

def list_coupons(store_name: str):
    ns, pod = resolve_store(store_name)
    args = ["wc", "shop_coupon", "list", "--format=json"]
    return run_wp_cli_command(ns, pod, args)


class CreateCouponInput(BaseModel):
    store_name: str
    code: str
    amount: str
    discount_type: str = "percent"
    description: Optional[str] = None
    individual_use: bool = False
    usage_limit: Optional[int] = None

def create_coupon(**kwargs):
    ns, pod = resolve_store(kwargs["store_name"])
    args = ["wc", "shop_coupon", "create"]

    for key in ["code", "amount", "discount_type", "description", "usage_limit"]:
        if kwargs.get(key) is not None:
            args.append(f"--{key}={kwargs[key]}")

    if kwargs.get("individual_use"):
        args.append("--individual_use=true")

    args.append("--porcelain")

    output = run_wp_cli_command(ns, pod, args)
    if output.startswith("Error:"):
        return json.dumps({"ok": False, "error": output})
    return json.dumps({"ok": True, "id": output.strip()})


class DeleteCouponInput(BaseModel):
    store_name: str
    id: int

def delete_coupon(store_name: str, id: int):
    ns, pod = resolve_store(store_name)
    args = ["wc", "shop_coupon", "delete", str(id), "--force"]
    return run_wp_cli_command(ns, pod, args)


# ============================================================
# CUSTOMERS
# ============================================================

class ListCustomersInput(BaseModel):
    store_name: str
    per_page: int = 10
    role: str = "all"

def list_customers(store_name: str, per_page: int = 10, role: str = "all"):
    ns, pod = resolve_store(store_name)
    args = [
        "wc", "customer", "list",
        f"--per_page={per_page}",
        f"--role={role}",
        "--format=json"
    ]
    return run_wp_cli_command(ns, pod, args)


class GetCustomerInput(BaseModel):
    store_name: str
    id: int

def get_customer(store_name: str, id: int):
    ns, pod = resolve_store(store_name)
    args = ["wc", "customer", "get", str(id), "--format=json"]
    return run_wp_cli_command(ns, pod, args)
    
    
# ============================================================
# ===================== POPUP MAKER ==========================
# ============================================================

class CreatePopupInput(BaseModel):
    store_name: str
    title: str
    content: str
    status: str = "publish"

def create_popup(store_name: str, title: str, content: str, status: str = "publish"):
    ns, pod = resolve_store(store_name)
    args = [
        "post", "create",
        "--post_type=popup",
        f"--post_title={title}",
        f"--post_content={content}",
        f"--post_status={status}",
        "--porcelain"
    ]
    return run_wp_cli_command(ns, pod, args)


class ListPopupsInput(BaseModel):
    store_name: str

def list_popups(store_name: str):
    ns, pod = resolve_store(store_name)
    args = ["post", "list", "--post_type=popup", "--format=json"]
    return run_wp_cli_command(ns, pod, args)
    
    
class UpdatePopupInput(BaseModel):
    store_name: str
    popup_id: int
    title: Optional[str] = None
    content: Optional[str] = None
    status: Optional[str] = None

def update_popup(**kwargs):
    ns, pod = resolve_store(kwargs["store_name"])

    args = ["post", "update", str(kwargs["popup_id"])]

    if kwargs.get("title"):
        args.append(f"--post_title={kwargs['title']}")
    if kwargs.get("content"):
        args.append(f"--post_content={kwargs['content']}")
    if kwargs.get("status"):
        args.append(f"--post_status={kwargs['status']}")

    return run_wp_cli_command(ns, pod, args)
    
    
class DeletePopupInput(BaseModel):
    store_name: str
    popup_id: int

def delete_popup(store_name: str, popup_id: int):
    ns, pod = resolve_store(store_name)
    args = ["post", "delete", str(popup_id), "--force"]
    return run_wp_cli_command(ns, pod, args)
    
    
class SetPopupSettingsInput(BaseModel):
    store_name: str
    popup_id: int
    settings: Dict[str, Any]

def set_popup_settings(store_name: str, popup_id: int, settings: Dict[str, Any]):
    ns, pod = resolve_store(store_name)

    # Get current settings
    current_raw = run_wp_cli_command(
        ns, pod,
        ["post", "meta", "get", str(popup_id), "_pum_popup_settings", "--format=json"]
    )

    try:
        current_settings = json.loads(current_raw) if current_raw else {}
    except:
        current_settings = {}

    if isinstance(current_settings, dict):
        current_settings.update(settings)
    else:
        current_settings = settings

    return run_wp_cli_command(
        ns, pod,
        ["post", "meta", "update",
         str(popup_id),
         "_pum_popup_settings",
         json.dumps(current_settings)]
    )


# ============================================================
# ===================== URUMI BANNER =========================
# ============================================================

class CreateBannerInput(BaseModel):
    store_name: str
    headline: str
    subheadline: Optional[str] = ""
    coupon: Optional[str] = ""
    cta_text: str = "Shop Now"
    enabled: bool = True

def urumi_create_banner(**kwargs):
    ns, pod = resolve_store(kwargs["store_name"])

    enabled = "true" if kwargs.get("enabled", True) else "false"

    args = [
        "urumi", "banner", "create",
        f"--headline={kwargs['headline']}",
        f"--subheadline={kwargs.get('subheadline', '')}",
        f"--coupon={kwargs.get('coupon', '')}",
        f"--cta_text={kwargs.get('cta_text', 'Shop Now')}",
        f"--enabled={enabled}"
    ]
    return run_wp_cli_command(ns, pod, args)


# ============================================================
# ===================== MAIL CATCHER =========================
# ============================================================

class CatcherListEmailsInput(BaseModel):
    store_name: str
    limit: int = 5

def catcher_list_emails(store_name: str, limit: int = 5):
    ns, pod = resolve_store(store_name)
    sql = f"SELECT * FROM wp_mail_logging ORDER BY id DESC LIMIT {limit}"
    return run_wp_cli_command(ns, pod, ["db", "query", sql, "--format=json"])


# ============================================================
# ===================== MAILPOET =============================
# ============================================================

class MailpoetListSubscribersInput(BaseModel):
    store_name: str

def mailpoet_list_subscribers(store_name: str):
    ns, pod = resolve_store(store_name)

    php = """
    try {
        if (!class_exists('\\MailPoet\\\\API\\\\API')) {
            echo json_encode(['ok'=>false,'error'=>'MailPoet not found']);
            exit;
        }
        $api = \\MailPoet\\\\API\\\\API::MP('v1');
        echo json_encode(['ok'=>true,'count'=>$api->getSubscriberCount()]);
    } catch (\\Exception $e) {
        echo json_encode(['ok'=>false,'error'=>$e->getMessage()]);
    }
    """
    return run_wp_cli_command(ns, pod, ["eval", php])


class MailpoetCreateCampaignInput(BaseModel):
    store_name: str
    subject: str
    body: str

def mailpoet_create_campaign(store_name: str, subject: str, body: str):
    ns, pod = resolve_store(store_name)

    php = f"""
    try {{
        $api = \\MailPoet\\\\API\\\\API::MP('v1');
        $newsletter = $api->saveNewsletter([
            'type'=>'standard',
            'subject'=>{json.dumps(subject)},
            'body'=>['content'=>{json.dumps(body)}]
        ]);
        echo json_encode(['ok'=>true,'id'=>$newsletter['id']]);
    }} catch (\\Exception $e) {{
        echo json_encode(['ok'=>false,'error'=>$e->getMessage()]);
    }}
    """
    return run_wp_cli_command(ns, pod, ["eval", php])


# ============================================================
# ===================== ELEMENTOR ============================
# ============================================================

class FlushCssInput(BaseModel):
    store_name: str

def flush_css(store_name: str):
    ns, pod = resolve_store(store_name)
    return run_wp_cli_command(ns, pod, ["elementor", "flush-css"])


class ReplaceUrlsInput(BaseModel):
    store_name: str
    old_url: str
    new_url: str

def replace_urls(store_name: str, old_url: str, new_url: str):
    ns, pod = resolve_store(store_name)
    return run_wp_cli_command(ns, pod, ["elementor", "replace-urls", old_url, new_url])
    
class LibrarySyncInput(BaseModel):
    store_name: str

def library_sync(store_name: str):
    ns, pod = resolve_store(store_name)
    return run_wp_cli_command(ns, pod, ["elementor", "library-sync"])


class SystemInfoInput(BaseModel):
    store_name: str

def system_info(store_name: str):
    ns, pod = resolve_store(store_name)
    return run_wp_cli_command(ns, pod, ["elementor", "system-info"])




# ============================================================
# REGISTER ALL
# ============================================================

ALL_TOOLS = [

    # ===================== WOOCOMMERCE =====================

    StructuredTool.from_function(
        list_products,
        name="list_products",
        description="List WooCommerce products with optional pagination and status filtering.",
        args_schema=ListProductsInput
    ),

    StructuredTool.from_function(
        get_product,
        name="get_product",
        description="Retrieve detailed information for a specific WooCommerce product by ID.",
        args_schema=GetProductInput
    ),

    StructuredTool.from_function(
        create_product,
        name="create_product",
        description="Create a new WooCommerce product with name, price, and optional metadata.",
        args_schema=CreateProductInput
    ),

    StructuredTool.from_function(
        update_product,
        name="update_product",
        description="Update fields of an existing WooCommerce product such as price, stock, or status.",
        args_schema=UpdateProductInput
    ),

    StructuredTool.from_function(
        delete_product,
        name="delete_product",
        description="Delete a WooCommerce product by ID. Can permanently remove if force is true.",
        args_schema=DeleteProductInput
    ),

    StructuredTool.from_function(
        list_orders,
        name="list_orders",
        description="List WooCommerce orders with optional filtering by status and pagination.",
        args_schema=ListOrdersInput
    ),

    StructuredTool.from_function(
        get_order,
        name="get_order",
        description="Retrieve detailed information for a specific WooCommerce order by ID.",
        args_schema=GetOrderInput
    ),

    StructuredTool.from_function(
        update_order,
        name="update_order",
        description="Update a WooCommerce order status or customer note.",
        args_schema=UpdateOrderInput
    ),

    StructuredTool.from_function(
        list_coupons,
        name="list_coupons",
        description="List all WooCommerce discount coupons.",
        args_schema=ListCouponsInput
    ),

    StructuredTool.from_function(
        create_coupon,
        name="create_coupon",
        description="Create a WooCommerce discount coupon with amount and discount type.",
        args_schema=CreateCouponInput
    ),

    StructuredTool.from_function(
        delete_coupon,
        name="delete_coupon",
        description="Delete a WooCommerce coupon permanently by ID.",
        args_schema=DeleteCouponInput
    ),

    StructuredTool.from_function(
        list_customers,
        name="list_customers",
        description="List WooCommerce customers with optional role and pagination filters.",
        args_schema=ListCustomersInput
    ),

    StructuredTool.from_function(
        get_customer,
        name="get_customer",
        description="Retrieve detailed information for a specific WooCommerce customer by ID.",
        args_schema=GetCustomerInput
    ),

    # ===================== POPUP MAKER =====================

    StructuredTool.from_function(
        create_popup,
        name="create_popup",
        description="Create a new Popup Maker popup with title and content.",
        args_schema=CreatePopupInput
    ),

    StructuredTool.from_function(
        list_popups,
        name="list_popups",
        description="List all Popup Maker popups for a store.",
        args_schema=ListPopupsInput
    ),

    StructuredTool.from_function(
        update_popup,
        name="update_popup",
        description="Update an existing Popup Maker popup's title, content, or status.",
        args_schema=UpdatePopupInput
    ),

    StructuredTool.from_function(
        delete_popup,
        name="delete_popup",
        description="Delete a Popup Maker popup permanently by ID.",
        args_schema=DeletePopupInput
    ),

    StructuredTool.from_function(
        set_popup_settings,
        name="set_popup_settings",
        description="Update advanced settings for a Popup Maker popup such as triggers or display conditions.",
        args_schema=SetPopupSettingsInput
    ),

    # ===================== URUMI =====================

    StructuredTool.from_function(
        urumi_create_banner,
        name="urumi_create_banner",
        description="Create or update a store-wide Urumi announcement banner.",
        args_schema=CreateBannerInput
    ),

    # ===================== MAIL CATCHER =====================

    StructuredTool.from_function(
        catcher_list_emails,
        name="catcher_list_emails",
        description="List recently captured outgoing emails from the store email logging system.",
        args_schema=CatcherListEmailsInput
    ),

    # ===================== MAILPOET =====================

    StructuredTool.from_function(
        mailpoet_list_subscribers,
        name="mailpoet_list_subscribers",
        description="Retrieve MailPoet subscriber statistics for the store.",
        args_schema=MailpoetListSubscribersInput
    ),

    StructuredTool.from_function(
        mailpoet_create_campaign,
        name="mailpoet_create_campaign",
        description="Create a new MailPoet email campaign with subject and HTML body.",
        args_schema=MailpoetCreateCampaignInput
    ),

    # ===================== ELEMENTOR =====================

    StructuredTool.from_function(
        flush_css,
        name="flush_css",
        description="Flush Elementor generated CSS cache.",
        args_schema=FlushCssInput
    ),

    StructuredTool.from_function(
        replace_urls,
        name="replace_urls",
        description="Replace old URLs with new URLs inside Elementor content.",
        args_schema=ReplaceUrlsInput
    ),

    StructuredTool.from_function(
        library_sync,
        name="library_sync",
        description="Synchronize the Elementor template library with the remote source.",
        args_schema=LibrarySyncInput
    ),

    StructuredTool.from_function(
        system_info,
        name="system_info",
        description="Retrieve Elementor system information and configuration details.",
        args_schema=SystemInfoInput
    ),
]

