from pipeline_steps import fetch_rdb

text = fetch_rdb("11376000", "2025-07-01", "2026-07-01")
print(f"response length: {len(text)}")
print("---first 500 chars---")
print(text[:500])
print("---last 300 chars---")
print(text[-300:])
