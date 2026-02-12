#!/usr/bin/env bash
# Sample product CSV + products.sh generation for WP-CLI job.

ensure_sample_csv() {
  # Create a tiny placeholder CSV if one doesn't exist.
  if [[ -f "$SAMPLE_CSV" ]]; then
    return
  fi
  log "Creating placeholder sample-products.csv..."
  mkdir -p "$(dirname "$SAMPLE_CSV")"
  cat <<'CSV' >"$SAMPLE_CSV"
ID,Type,SKU,Name,Published,"Is featured?","Visibility in catalog","Short description",Description,"Date sale price starts","Date sale price ends","Tax status","Tax class","In stock?",Stock,"Low stock amount","Backorders allowed?","Sold individually?","Weight (kg)","Length (cm)","Width (cm)","Height (cm)","Allow customer reviews?","Purchase note","Sale price","Regular price",Categories,Tags,"Shipping class",Images,"Download limit","Download expiry days",Parent,"Grouped products",Upsells,Cross-sells,"External URL","Button text",Position
1,simple,,Sample Product,1,0,visible,Sample product,Sample product,,,taxable,,1,,,0,0,,,,,1,,,9.99,9.99,Sample,,"",,,,,,,0
CSV
}

# Generate products.sh from CSV (Robust version with Images, Attributes, & Prices)
generate_products_script() {
  PRODUCTS_SH="$ROOT_DIR/charts/ecommerce-store/files/products.sh"
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 not found; skipping products.sh generation." >&2
    return
  fi
  python3 - "$SAMPLE_CSV" "$PRODUCTS_SH" <<'PY'
import csv, sys, shlex, json

csv_path, out_path = sys.argv[1], sys.argv[2]

def clean_key(row, key):
    return (row.get(key) or "").strip()

with open(csv_path, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    rows = list(reader)

with open(out_path, 'w', encoding='utf-8') as out:
    out.write("#!/bin/sh\n")
    out.write("set +e\n")
    
    for row in rows:
        name = clean_key(row, "Name")
        if not name:
            continue

        # Base parts
        parts = ["wp", "wc", "product", "create"]
        parts.append(f"--name={shlex.quote(name)}")
        parts.append("--user=${WP_ADMIN_USER}")
        parts.append("--allow-root")

        # 1. Status
        published = clean_key(row, "Published")
        status = "publish" if published == "1" else "draft"
        parts.append(f"--status={status}")

        # 2. Type (Map 'variation' to 'simple' to ensure they create successfully without parent IDs)
        p_type = clean_key(row, "Type")
        if p_type == "variation":
            p_type = "simple" 
        if p_type:
            parts.append(f"--type={p_type}")

        # 3. Prices
        reg_price = clean_key(row, "Regular price")
        if reg_price: parts.append(f"--regular_price={reg_price}")

        sale_price = clean_key(row, "Sale price")
        if sale_price: parts.append(f"--sale_price={sale_price}")

        # 4. Content
        desc = clean_key(row, "Description")
        if desc: parts.append(f"--description={shlex.quote(desc)}")

        short_desc = clean_key(row, "Short description")
        if short_desc: parts.append(f"--short_description={shlex.quote(short_desc)}")
        
        sku = clean_key(row, "SKU")
        if sku: parts.append(f"--sku={shlex.quote(sku)}")

        # 5. Images (CSV: "url1, url2" -> JSON: '[{"src":"url1"}, ...]')
        images_raw = clean_key(row, "Images")
        if images_raw:
            urls = [u.strip() for u in images_raw.split(',') if u.strip()]
            if urls:
                imgs_data = [{"src": u} for u in urls]
                parts.append(f"--images={shlex.quote(json.dumps(imgs_data))}")

        # 6. Attributes (Size, Color, etc.)
        attributes = []
        for i in range(1, 4):
            attr_name = clean_key(row, f"Attribute {i} name")
            attr_vals = clean_key(row, f"Attribute {i} value(s)")
            if attr_name and attr_vals:
                # 'global' column is usually 1 or 0
                is_visible = clean_key(row, f"Attribute {i} visible") != "0"
                options = [x.strip() for x in attr_vals.split(",")]
                attributes.append({
                    "name": attr_name,
                    "visible": is_visible,
                    "variation": True,
                    "options": options
                })
        
        if attributes:
            parts.append(f"--attributes={shlex.quote(json.dumps(attributes))}")

        # Write command
        out.write(" ".join(parts) + " || true\n")
PY
  chmod +x "$PRODUCTS_SH" >/dev/null 2>&1 || true
}
