extends RefCounted

# Watch "events": what the "listen" plan key captured — signal name, node, frame and arguments.
#
# The log keeps its records across steps, so a multi-step experiment can subscribe once and read
# the whole story at the end. Use {"listen": {"clear": true}} to start a fresh slice.
#
# Capability contract (duck typed, no base class): key() / collect().

# --- Public Functions ---

func key() -> String:
	return "events"


func collect(p_context) -> Variant:
	return p_context.events.snapshot(p_context.tree().root)
