extends RefCounted

# Shared context handed to every input and observer.
#
# It owns the capability registries (plan key -> input handler, watch key -> observer) and is the
# only thing a capability needs. Adding a capability means adding one script path to the two
# arrays in probe_node.gd; nothing in this file changes.
#
# Capabilities are plain RefCounted objects resolved by duck typing, not a base class: that keeps
# every capability file free of path coupling, so the whole tree can be moved around.

const ErrorSink := preload("res://debug_probe/core/error_sink.gd")
const EventLog := preload("res://debug_probe/core/event_log.gd")

# What a step can count: physics ticks, or render (idle) frames. Advertised in the hello message.
const UNITS: Array[String] = ["physics", "idle"]

# --- Public Vars ---

var host: Node = null                # the probe node
var physics_frames: int = 0          # physics ticks advanced since the probe took over
var idle_frames: int = 0             # render frames advanced since the probe took over
var frame_unit: String = "physics"   # which of the two the step in flight counts
var results: Array[Dictionary] = []  # side results of the step in flight (a click, ...)
var settings: Dictionary = {}        # the probe node's exported options, read by capabilities
var error_sink: ErrorSink = null     # the Logger owned by the probe node (see observe_errors)
var probe_targets: Array[Dictionary] = []  # "probe" subscriptions, read by observe_props
var contact_targets: Array[String] = []    # "contact" subscriptions, read by observe_contacts
var checks: Dictionary = {}          # frame offset -> assertions scheduled by "check"
var events: EventLog = EventLog.new()  # "listen" subscriptions and what they captured
var replay_request: Dictionary = {}   # "replay" intent for the step in flight (see step_runner)
var queries: Dictionary = {}          # frame offset -> physics queries scheduled by "query"
var query_results: Dictionary = {}    # "as" label -> latest query answer (sticky)

# --- Private Vars ---

var _inputs: Dictionary = {}     # plan key -> handler
var _observers: Dictionary = {}  # watch key -> observer

# --- Built-in Functions ---

func _init(p_host: Node, p_input_scripts: Array, p_observer_scripts: Array) -> void:
	host = p_host
	for script: GDScript in p_input_scripts:
		var handler: Variant = script.new()
		for key: Variant in handler.keys():
			_inputs[str(key)] = handler
	for script: GDScript in p_observer_scripts:
		var observer: Variant = script.new()
		_observers[str(observer.key())] = observer

# --- Public Functions ---

func tree() -> SceneTree:
	return host.get_tree()


func viewport() -> Viewport:
	return host.get_viewport()


func now() -> float:
	return Time.get_ticks_msec() / 1000.0


# Units a step can advance, in registration order.
func units() -> Array[String]:
	return UNITS


# The frame number a sample or an event should be labelled with: the counter of the unit the
# current step is advancing, plus one (frames are 1-based for the caller).
func frame_now() -> int:
	return (idle_frames if frame_unit == "idle" else physics_frames) + 1


# Plan keys this build accepts, in registration order.
func input_keys() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in _inputs.keys():
		out.append(str(key))
	return out


# Watch keys this build accepts, in registration order.
func observe_keys() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in _observers.keys():
		out.append(str(key))
	return out


# Request validation lives on the editor side only (probe_step_tool._unsupported): the hello built
# from _inputs / _observers is what it validates against, so a second copy here could only disagree
# with the list this build actually advertises.

# Runs every instruction planned for this frame offset.
func apply_plan(p_plan: Array, p_index: int) -> void:
	for entry: Variant in p_plan:
		if typeof(entry) != TYPE_DICTIONARY or int(entry.get("at", -1)) != p_index:
			continue
		for key: Variant in entry.keys():
			var name: String = str(key)
			if name == "at":
				continue
			var handler: Variant = _inputs.get(name)
			if handler == null:
				continue
			var out: Variant = handler.apply(name, entry[key], self, p_index)
			if out != null:
				results.append(out)


# Collects the requested observations for the frame that just ended.
func collect(p_watch: Array) -> Dictionary:
	var sample: Dictionary = {"frame": frame_now()}
	for raw: Variant in p_watch:
		var name: String = str(raw)
		var observer: Variant = _observers.get(name)
		if observer != null:
			sample[name] = observer.collect(self)
	return sample


# Releases anything an input is holding (scene change, disconnect, exit). Handlers that hold
# something implement cleanup(); the rest (a hover, for instance) have nothing to release and
# simply omit it, so the method is looked up instead of assumed.
func cleanup_inputs() -> void:
	for key: Variant in _inputs:
		var handler: Variant = _inputs[key]
		if handler.has_method("cleanup"):
			handler.cleanup()


# Keeps held inputs held for one more frame. A window focus change drops the virtual action state,
# and a hold that silently stops mid-step looks exactly like a game bug; handlers that hold
# something implement keep(), the rest do not care.
func keep_inputs() -> void:
	for key: Variant in _inputs:
		var handler: Variant = _inputs[key]
		if handler.has_method("keep"):
			handler.keep()
