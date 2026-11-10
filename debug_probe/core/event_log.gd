extends RefCounted

# Records of the signals the "listen" plan key subscribed to: what fired, on which node, in which
# frame. This is the piece that turns "the state should have changed" into "it emitted
# level_completed at frame 42".
#
# The log owns its subscriptions, so reconnecting after a scene change is one call
# (ensure_links) instead of something every caller has to remember. Records are capped: a signal
# that fires every frame must not turn a sample into a megabyte of JSON, so the oldest are dropped
# and counted.

# --- Constants ---

const Value := preload("res://debug_probe/core/value.gd")

const MAX_RECORDS: int = 200

# --- Public Vars ---

var dropped: int = 0

# --- Private Vars ---

var _records: Array[Dictionary] = []
var _subs: Array[Dictionary] = []
var _seq: int = 0

# --- Public Functions ---

# Subscribes to one signal. The result says whether it bound right away: a node that does not
# exist yet, or a signal name that is misspelled, has to be visible instead of silently quiet.
func subscribe(p_context, p_path: String, p_signal: String) -> Dictionary:
	for existing: Dictionary in _subs:
		if str(existing.get("path", "")) == p_path and str(existing.get("signal", "")) == p_signal:
			existing.bound = _bind(existing, p_context.tree().root)
			return existing
	var sub: Dictionary = {"path": p_path, "signal": p_signal}
	# Up to four signal arguments are recorded: a lambda cannot be variadic, and game signals that
	# carry more than four payload arguments are rare enough to be worth the limit.
	sub.callable = func(p_a: Variant = null, p_b: Variant = null, p_c: Variant = null,
			p_d: Variant = null) -> void:
		_append(p_context, p_path, p_signal, [p_a, p_b, p_c, p_d])
	_subs.append(sub)
	_bind(sub, p_context.tree().root)
	return sub


func unsubscribe_all() -> void:
	for sub: Dictionary in _subs:
		var node: Node = _node(sub)
		# has_signal first: is_connected() on a name the node does not have raises an engine error,
		# which would land in the probe's own "errors" sample as if the game had failed.
		if node != null and node.has_signal(str(sub.signal)) \
				and node.is_connected(str(sub.signal), sub.callable):
			node.disconnect(str(sub.signal), sub.callable)
	_subs.clear()


func clear_records() -> void:
	_records.clear()
	dropped = 0
	for sub: Dictionary in _subs:
		sub["count"] = 0


func subscription_count() -> int:
	return _subs.size()


# Reconnects anything that lost its node (scene reload, node replaced): called before a snapshot,
# so a capture does not quietly stop working after the first scene change.
func ensure_links(p_root: Node) -> void:
	for sub: Dictionary in _subs:
		if not _is_bound(sub):
			_bind(sub, p_root)


# Whether a subscription currently points at a live node and is connected.
func is_bound(p_sub: Dictionary) -> bool:
	return _is_bound(p_sub)


func snapshot(p_root: Node) -> Dictionary:
	ensure_links(p_root)
	var links: Array[Dictionary] = []
	for sub: Dictionary in _subs:
		links.append({"path": str(sub.path), "signal": str(sub.signal),
			"bound": _is_bound(sub), "count": int(sub.get("count", 0))})
	return {
		"count": _records.size(),
		"dropped": dropped,
		"subscriptions": links,
		"items": _records,
	}

# --- Private Functions ---

func _node(p_sub: Dictionary) -> Node:
	var node: Variant = p_sub.get("node", null)
	if node == null or not is_instance_valid(node):
		return null
	return node


func _is_bound(p_sub: Dictionary) -> bool:
	var node: Node = _node(p_sub)
	if node == null:
		return false
	# A misspelled signal must read as "not bound", not as an engine error: subscribe() already
	# reports it, and is_connected() on a name that does not exist raises one.
	var signal_name: String = str(p_sub.get("signal", ""))
	if not node.has_signal(signal_name):
		return false
	return node.is_connected(signal_name, p_sub.callable)


# Points a subscription at the node its path currently resolves to, and connects if needed.
func _bind(p_sub: Dictionary, p_root: Node) -> bool:
	var path: String = str(p_sub.get("path", ""))
	var signal_name: String = str(p_sub.get("signal", ""))
	var node: Node = p_root.get_node_or_null(path)
	p_sub["node"] = node
	if node == null:
		p_sub["error"] = "no such node"
		return false
	if not node.has_signal(signal_name):
		p_sub["error"] = "no such signal on %s" % node.get_class()
		return false
	p_sub["error"] = ""
	if not node.is_connected(signal_name, p_sub.callable):
		node.connect(signal_name, p_sub.callable)
	return true


func _append(p_context, p_path: String, p_signal: String, p_args: Array) -> void:
	# A lambda cannot be variadic, so the tail is padded with nulls: trimming them is the only way
	# to tell "two arguments" from "four arguments".
	var args: Array = []
	for raw: Variant in p_args:
		args.append(Value.simplify(raw))
	while not args.is_empty() and args[args.size() - 1] == null:
		args.pop_back()

	if _records.size() >= MAX_RECORDS:
		_records.pop_front()
		dropped += 1
	_seq += 1
	_records.append({
		"seq": _seq,
		# The frame the game was in while emitting; matches the "frame" field of a sample.
		"frame": p_context.frame_now(),
		"node": p_path,
		"signal": p_signal,
		"args": args,
	})
	for sub: Dictionary in _subs:
		if str(sub.get("path", "")) == p_path and str(sub.get("signal", "")) == p_signal:
			sub["count"] = int(sub.get("count", 0)) + 1
			return
