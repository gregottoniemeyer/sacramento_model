from pipeline_steps import fetch_rdb

for name, site in [("mccloud", "11367500"), ("feather", "11407000")]:
    print(f"\n--- {name} ({site}) ---")
    text = fetch_rdb(site, "2026-04-27", "2026-07-01")
    print(f"response length: {len(text)}")
    print(text[:600])
