class_name AiDebugProbe
extends Node

## Game-side frame-stepped probe. Add this node to the scene under test (or let a host scene add
## it) and run the game; an editor-side channel then drives it.
##
## Model: takes over SceneTree.paused on _ready. A step request advances exactly N frames and then
## pauses again; the frames are physics ticks by default, or render frames when the request asks
## for `"unit": "idle"` (for projects whose logic lives in _process). Inputs are injected as a
## pipeline: the first frame's input goes in before the frame is let through, every later frame's
## input is injected at the end of the frame before it.
##
## Running order inside one physics frame:
##   game nodes (priority < 1000) read the input injected last frame and move
##   this node (priority 1000) samples the end of the frame, then injects the next frame's input
## That ordering, not signal timing, is what makes a step exactly one frame.
##
## Everything that knows *what* to inject or *what* to sample lives in inputs/ and observes/;
## this file only owns the lifecycle, the routing and the pause control.

# --- Constants ---

const CAPTURE: String = "ai_debug_probe"
const VERSION: String = "0.12.0"
const MAX_FRAMES: int = 600

const ProbeContext := preload("res://debug_probe/core/probe_context.gd")
const StepRunner := preload("res://debug_probe/core/step_runner.gd")
const ProbeIo := preload("res://debug_probe/core/probe_io.gd")
const ErrorSink := preload("res://debug_probe/core/error_sink.gd")

# --- Capability Registries ---
#
# Adding a capability is one line here. The hello message and the editor's request validation
# are both derived from these arrays, so nothing else has to be kept in sync.

const OBSERVERS: Array = [
	preload("res://debug_probe/observes/observe_pose.gd"),
	preload("res://debug_probe/observes/observe_contacts.gd"),
	preload("res://debug_probe/observes/observe_actors.gd"),
	preload("res://debug_probe/observes/observe_props.gd"),
	preload("res://debug_probe/observes/observe_events.gd"),
	preload("res://debug_probe/observes/observe_queries.gd"),
	preload("res://debug_probe/observes/observe_errors.gd"),
	preload("res://debug_probe/observes/observe_scene.gd"),
	preload("res://debug_probe/observes/observe_ui.gd"),
]

const INPUTS: Array = [
	preload("res://debug_probe/inputs/input_press.gd"),
	preload("res://debug_probe/inputs/input_click.gd"),
	preload("res://debug_probe/inputs/input_type.gd"),
	preload("res://debug_probe/inputs/input_set.gd"),
	preload("res://debug_probe/inputs/input_drag.gd"),
	preload("res://debug_probe/inputs/input_probe.gd"),
	preload("res://debug_probe/inputs/input_check.gd"),
	preload("res://debug_probe/inputs/input_listen.gd"),
	preload("res://debug_probe/inputs/input_replay.gd"),
	preload("res://debug_probe/inputs/input_query.gd"),
	preload("res://debug_probe/inputs/input_contact.gd"),
	preload("res://debug_probe/inputs/input_hover.gd"),
	preload("res://debug_probe/inputs/input_select.gd"),
]

# --- @export Vars ---

## Seconds without a request before pause control is handed back, counted from the moment the probe
## takes over. 0 disables auto release. Once a step request has arrived the AI owns the pause and
## auto release stays off: steps are seconds to minutes apart (that is model latency), so releasing
## between them would let the game run freely and make every step start from a different state.
@export var auto_release_seconds: float = 3.0

## Player to report: an absolute node path, or one relative to this node. Empty: the "player"
## group first, then the first CharacterBody in the scene.
@export var player_path: NodePath = ^""

# --- Private Vars ---

var _context: ProbeContext = null
var _runner: StepRunner = null
var _io: ProbeIo = null
var _sink: ErrorSink = null
var _taken: bool = false
var _had_request: bool = false
var _paused_before: bool = false
var _last_request_at: float = 0.0

# --- Built-in Functions ---

func _ready() -> void:
	if not EngineDebugger.is_active():
		return
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Run after the game's nodes: sample the end of a frame, then inject the next frame's input.
	# Both priorities are needed: since 4.4 process_priority only orders _process, and
	# process_physics_priority (default 0) orders _physics_process.
	process_priority = 1000
	process_physics_priority = 1000
	_sink = ErrorSink.new()
	OS.add_logger(_sink)
	_context = ProbeContext.new(self, INPUTS, OBSERVERS)
	_context.settings = {"player_path": player_path}
	_context.error_sink = _sink
	_runner = StepRunner.new(_context, MAX_FRAMES)
	_runner.finished.connect(_on_finished)
	_io = ProbeIo.new(CAPTURE)
	EngineDebugger.register_message_capture(CAPTURE, _on_editor_message)
	_take_control()
	_io.send("hello", _io.hello(_context, VERSION, MAX_FRAMES))


func _process(p_delta: float) -> void:
	if _runner == null:
		return
	# Render frames are a unit a step can count, so they are offered to the runner first; the
	# watchdog below only fires when the frame count stops moving.
	_runner.on_idle_frame(p_delta)
	_runner.on_idle()
	if not _taken or _had_request or auto_release_seconds <= 0.0:
		return
	if _context.now() - _last_request_at > auto_release_seconds:
		_release()
		_io.send("idle", {})


func _physics_process(_p_delta: float) -> void:
	if _runner == null or not _runner.is_running():
		return
	_runner.on_frame_end()


func _exit_tree() -> void:
	# Release first: it restores the pause state before it touches any capability, so a capability
	# that errors on the way out cannot leave the game frozen. The second cleanup covers the case
	# where the probe had already released (nothing held, so nothing to do) — kept for symmetry.
	_release()
	if _context != null:
		_context.cleanup_inputs()
		# Signal subscriptions are the one thing an input's cleanup() cannot drop: the contract is
		# called without a context, so the callables captured in the shared EventLog would otherwise
		# keep this context alive and keep firing into a probe that is already gone.
		_context.events.unsubscribe_all()
	if EngineDebugger.is_active() and EngineDebugger.has_capture(CAPTURE):
		EngineDebugger.unregister_message_capture(CAPTURE)
	if _sink != null:
		OS.remove_logger(_sink)
		_sink = null

# --- Private Functions ---

# Takes over pause control, remembering the previous value.
func _take_control() -> void:
	if _taken:
		return
	_taken = true
	_paused_before = get_tree().paused
	get_tree().paused = true
	_last_request_at = _context.now()


# Hands pause control back and drops every held input: the game must not inherit a stuck key.
# The pause state is restored BEFORE the capabilities are cleaned up: a capability error escapes
# the call chain (see the note below), and the game must not be left frozen by it.
#
# Why the order matters at all: a GDScript runtime error does not unwind to the caller as an
# exception, it terminates the whole call chain it happens in — so an error inside cleanup_inputs()
# would skip every line after it here, including the unpause. Worse, an error escaping _process()
# stops this node's process callbacks for the rest of the run (measured in 4.8 beta2), which is why
# a broken capability must never be able to throw in the first place.
func _release() -> void:
	if not _taken:
		return
	_taken = false
	get_tree().paused = _paused_before
	if _context != null:
		_context.cleanup_inputs()


# Editor request entry point: a step request, or nothing.
func _on_editor_message(p_message: String, p_data: Array) -> bool:
	if p_message != "request" or p_data.is_empty():
		return false
	var payload: Variant = JSON.parse_string(str(p_data[0]))
	if typeof(payload) != TYPE_DICTIONARY:
		return false
	_last_request_at = _context.now()
	_had_request = true
	_take_control()
	if not _runner.start(payload):
		_io.reply(payload, false, "a step is already running")
		return true
	get_tree().paused = false
	return true


# The runner finished, or gave up: pause again and answer.
func _on_finished(p_payload: Dictionary, p_ok: bool, p_body: Variant) -> void:
	get_tree().paused = true
	_io.reply(p_payload, p_ok, p_body)
