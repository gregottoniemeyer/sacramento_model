from pipeline_steps import fetch_rdb

text = fetch_rdb("11376000", "2025-07-01", "2026-07-01")
# strip tags crudely just to read the message
import re
clean = re.sub('<[^<]+?>', ' ', text)
clean = ' '.join(clean.split())
print(clean)
