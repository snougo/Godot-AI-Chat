extends RefCounted

# Watch "errors": the errors and script errors captured since the previous sample.
#
# The sink is owned by the probe node (one Logger registration per game), not by this observer:
# several Logger instances would each get a copy of every message, and drain() would then depend
# on which observer ran first.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Public Functions ---

func key() -> String:
	return "errors"


func collect(p_context) -> Variant:
	if p_context.error_sink == null:
		return []
	return p_context.error_sink.drain()
