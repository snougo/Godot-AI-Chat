extends Logger

# Captures push_error, script errors and engine errors into a bounded buffer.
#
# A Logger, so it can be called from any thread; drain() is called from the game thread only.
# Kept out of the probe node so the "errors" observer (and any future detector) can use it.

# --- Constants ---

const MAX_LINES: int = 500
const MAX_MESSAGE: int = 500

# --- Public Vars ---

var mutex: Mutex = Mutex.new()
var lines: Array[Dictionary] = []
# Errors thrown away because the buffer was full. Counted instead of silent: losing errors without
# saying so would make "no errors" mean two different things. Lifetime total — drain() does not
# reset it.
#
# Reserved: written, never read. The "errors" sample still returns the array as-is; exposing this
# count would mean turning the sample into {items, dropped}, which breaks every existing assertion
# path ("errors/0/message"). Whoever wires it up should first fix the semantics — lifetime total vs
# "since the last sample" — and then change the sample shape.
var dropped: int = 0

# --- Public Functions ---

func drain() -> Array[Dictionary]:
	mutex.lock()
	var out: Array[Dictionary] = []
	out.assign(lines)
	lines.clear()
	mutex.unlock()
	return out

# --- Virtual Interface ---

func _log_error(p_function: String, p_file: String, p_line: int, p_code: String, p_rationale: String,
		_p_editor_notify: bool, p_error_type: int, p_backtraces: Array[ScriptBacktrace]) -> void:
	var where: String = "%s:%d" % [p_file, p_line]
	# push_error reports the engine's own location: the script's location is the backtrace's first frame
	for bt: ScriptBacktrace in p_backtraces:
		if bt != null and bt.get_frame_count() > 0:
			where = "%s:%d" % [bt.get_frame_file(0), bt.get_frame_line(0)]
			break
	mutex.lock()
	# The buffer keeps the NEWEST errors: a full buffer drops its oldest line instead of refusing the
	# new one. Losing the error that just happened would defeat the point — it is the one the caller
	# is about to ask about.
	if lines.size() >= MAX_LINES:
		lines.pop_front()
		dropped += 1
	lines.append({
		"type": p_error_type,
		"message": (p_rationale if p_rationale != "" else p_code).substr(0, MAX_MESSAGE),
		"where": where,
		"function": p_function,
	})
	mutex.unlock()


func _log_message(_p_message: String, _p_error: bool) -> void:
	pass
