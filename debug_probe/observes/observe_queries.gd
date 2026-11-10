extends RefCounted

# Watch "queries": the latest answer of every label the "query" plan key asked about.
#
# Sticky on purpose: a ray cast once at frame 30 is still readable at frame 200, so a "check" can
# assert on it later without re-casting. Watching this key also puts geometry into "replay" diffs.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Public Functions ---

func key() -> String:
	return "queries"


func collect(p_context) -> Variant:
	if p_context.query_results.is_empty():
		return {"error": "nothing queried; use the \"query\" plan key first"}
	return p_context.query_results
