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

generate_products_script() {
  # Convert CSV rows to WP-CLI commands (best-effort).
  PRODUCTS_SH="$ROOT_DIR/charts/ecommerce-store/files/products.sh"
  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; skipping products.sh generation."
    return
  fi
  python3 - "$SAMPLE_CSV" "$PRODUCTS_SH" <<'PY'
import csv, sys, shlex
csv_path, out_path = sys.argv[1], sys.argv[2]
with open(csv_path, newline='', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    rows = list(reader)
with open(out_path, 'w', encoding='utf-8') as out:
    out.write("#!/bin/sh\n")
    out.write("set +e\n")
    for row in rows:
        name = (row.get("Name") or "").strip()
        if not name:
            continue
        price = (row.get("Regular price") or row.get("Sale price") or "10").strip()
        desc = (row.get("Description") or "").strip()
        short = (row.get("Short description") or "").strip()
        parts = [
            "wp wc product create",
            f"--name={shlex.quote(name)}",
            f"--regular_price={shlex.quote(price)}",
            f"--status=publish",
            f"--user=${{WP_ADMIN_USER}}",
            "--allow-root",
        ]
        if desc:
            parts.append(f"--description={shlex.quote(desc)}")
        if short:
            parts.append(f"--short_description={shlex.quote(short)}")
        out.write(" ".join(parts) + " || true\n")
PY
  chmod +x "$PRODUCTS_SH" >/dev/null 2>&1 || true
}
