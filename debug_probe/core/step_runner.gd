extends RefCounted

# Frame scheduler: turns one step request into N frames of pipeline injection.
#
# A step counts one of two units (see ProbeContext.UNITS):
#   "physics"  physics ticks — deterministic, the default, driven by probe_node._physics_process
#   "idle"     render frames — for projects whose logic lives in _process; the delta varies with
#               real time, so it advances frames but cannot promise reproducible numbers
#
# Pure logic — it never touches the tree, the debugger or the scene. probe_node calls
# on_frame_end() from _physics_process, on_idle_frame() and on_idle() from _process, then forwards
# whatever finished carries. Keeping it free of Node and IO is what lets it be tested alone.

# --- Signals ---

signal finished(p_payload: Dictionary, p_ok: bool, p_body: Variant)

# --- Constants ---

const ProbeContext := preload("res://debug_probe/core/probe_context.gd")
const Check := preload("res://debug_probe/core/check.gd")
const Diff := preload("res://debug_probe/core/diff.gd")
const ReplayStore := preload("res://debug_probe/core/replay_store.gd")
const SpaceQuery := preload("res://debug_probe/core/space_query.gd")

const WATCHDOG_SECONDS: float = 2.0
const DEFAULT_WATCH: Array[String] = ["pose", "errors"]

# --- Public Vars ---

var max_frames: int = 600

# --- Private Vars ---

var _context: ProbeContext = null
var _job: Dictionary = {}  # the step in flight; empty when idle
var _last_progress_at: float = 0.0
var _last_frames_done: int = -1

# --- Built-in Functions ---

func _init(p_context: ProbeContext, p_max_frames: int) -> void:
	_context = p_context
	max_frames = p_max_frames

# --- Public Functions ---

func is_running() -> bool:
	return not _job.is_empty()


# Starts a step. Returns false when one is already running.
func start(p_payload: Dictionary) -> bool:
	if is_running():
		return false
	var requested: int = int(p_payload.get("frames", 1))
	var frames: int = clampi(requested, 1, max_frames)
	var samples: Array[Dictionary] = []
	_context.results = []
	_context.checks = {}
	_context.queries = {}
	_context.replay_request = {}
	# A request that is not carried out literally says so: a plan entry that never happens already
	# reports itself (_note_dropped_actions), and a clamped frame count follows the same rule.
	if frames != requested:
		_context.results.append({"kind": "plan", "at": -1, "clamped": true,
			"error": "a step runs between 1 and %d frames: %d requested, %d used" % [
				max_frames, requested, frames]})
	var step_unit: String = str(p_payload.get("unit", "physics"))
	if not ProbeContext.UNITS.has(step_unit):
		# Loud, not silent: a typo in the unit would otherwise look like a physics step.
		_context.results.append({"kind": "plan", "unit": step_unit, "dropped": true,
			"error": "unknown unit '%s' (supported: %s); using physics" % [step_unit, ", ".join(ProbeContext.UNITS)]})
		step_unit = "physics"
	_context.frame_unit = step_unit
	_job = {
		"payload": p_payload,
		"frames": frames,
		"unit": step_unit,
		"plan": p_payload.get("plan", []),
		"watch": p_payload.get("watch", DEFAULT_WATCH),
		"sample_at": _sample_offsets(p_payload, frames),
		"frames_done": 0,
		"samples": samples,
		"next_plan": 0,
	}
	# The first frame's input goes in before the frame is let through.
	_context.apply_plan(_job.plan, 0)
	_note_dropped_actions(_job.plan, frames)
	_job.next_plan = 1
	_last_frames_done = -1
	_last_progress_at = _context.now()
	return true


# Called at the end of every physics frame. The probe runs last in the frame, so every other
# node's _physics_process for this frame is already done.
func on_frame_end() -> void:
	if not is_running() or unit() != "physics":
		return
	_advance(0.0)


# Called at the end of every render frame. Same contract as on_frame_end(), other unit.
func on_idle_frame(p_delta: float) -> void:
	if not is_running() or unit() != "idle":
		return
	_advance(p_delta)


# Which unit the step in flight counts.
func unit() -> String:
	return str(_job.get("unit", "physics"))


# Watchdog: a step whose frame count stops advancing is wedged (a script error inside a sample
# leaves the runner busy and no reply ever arrives). Report it instead of hanging forever.
func on_idle() -> void:
	if not is_running():
		return
	if _job.frames_done != _last_frames_done:
		_last_frames_done = _job.frames_done
		_last_progress_at = _context.now()
		return
	if _context.now() - _last_progress_at > WATCHDOG_SECONDS:
		var payload: Dictionary = _job.payload
		_job = {}
		finished.emit(payload, false, "the step stopped advancing: see the editor's Errors tab")

# --- Private Functions ---

# One frame is over: answer the question about it, then set up the next one. Both units share this;
# only the counter and the reported dt differ.
func _advance(p_delta: float) -> void:
	var is_idle: bool = unit() == "idle"
	if is_idle:
		_job.dt_sum = float(_job.get("dt_sum", 0.0)) + p_delta
		_job.dt_max = maxf(float(_job.get("dt_max", 0.0)), p_delta)
	_run_queries(_job.frames_done)
	if _job.sample_at.has(_job.frames_done):
		_job.samples.append(_context.collect(_job.watch))
	_run_checks(_job.frames_done)
	_job.frames_done += 1
	if is_idle:
		_context.idle_frames += 1
	else:
		_context.physics_frames += 1
	if _job.frames_done >= _job.frames:
		_finish_step()
		return
	# Pipeline: inject the next frame's input now, so the game's nodes read it next frame.
	_context.apply_plan(_job.plan, _job.next_plan)
	_job.next_plan += 1
	_context.keep_inputs()
	Input.flush_buffered_events()


func _finish_step() -> void:
	var payload: Dictionary = _job.payload
	var is_idle: bool = unit() == "idle"
	var counter: int = _context.idle_frames if is_idle else _context.physics_frames
	var body: Dictionary = {
		"unit": unit(),
		"frame_start": counter - _job.frames,
		"frame_end": counter,
		"dt": (float(_job.get("dt_sum", 0.0)) / float(_job.frames)) if is_idle \
				else 1.0 / float(Engine.physics_ticks_per_second),
		"results": _context.results,
		"samples": _job.samples,
	}
	if is_idle:
		# Render deltas vary with real time: report the spread so nobody reads them as fixed.
		body.dt_max = _job.get("dt_max", 0.0)
	_handle_replay(body, _job)
	_job = {}
	finished.emit(payload, true, body)

# Records this step as a baseline, or compares it against the stored one. Runs after the body is
# assembled, so a baseline holds exactly what the caller would have seen.
func _handle_replay(p_body: Dictionary, p_job: Dictionary) -> void:
	if not _context.replay_request.has("id"):
		return
	var id: String = str(_context.replay_request.id)
	var mode: String = str(_context.replay_request.get("mode", "compare"))
	var record: Dictionary = {
		"frames": int(p_job.frames),
		"watch": p_job.watch,
		"plan": p_job.plan,
		"samples": p_body.samples,
		"results": _stable_results(p_body.results),
	}
	match mode:
		"record":
			var err: int = ReplayStore.save(id, record)
			p_body.replay = {"id": id, "mode": mode, "saved": err == OK,
				"file": ReplayStore.path_of(id), "frames": int(p_job.frames),
				"error": "" if err == OK else error_string(err)}
		"clear":
			p_body.replay = {"id": id, "mode": mode, "cleared": ReplayStore.clear(id)}
		_:
			_compare_replay(p_body, p_job, id, mode, record)


# The "replay" row differs by construction (record vs compare), so it must not turn into a
# difference: everything else in results is part of the run.
func _stable_results(p_results: Array) -> Array:
	var out: Array = []
	for row: Variant in p_results:
		if typeof(row) == TYPE_DICTIONARY and str((row as Dictionary).get("kind", "")) == "replay":
			continue
		out.append(row)
	return out


func _compare_replay(p_body: Dictionary, p_job: Dictionary, p_id: String, p_mode: String,
		p_record: Dictionary) -> void:
	var baseline: Dictionary = ReplayStore.load_record(p_id)
	if baseline.is_empty():
		p_body.replay = {"id": p_id, "mode": p_mode, "identical": false,
			"file": ReplayStore.path_of(p_id),
			"error": "no baseline for '%s'; record one first" % p_id}
		return
	var result: Dictionary = Diff.compare(
		{"samples": baseline.get("samples", []), "results": baseline.get("results", [])},
		{"samples": p_record.samples, "results": p_record.results})
	result.id = p_id
	result.mode = p_mode
	result.frames = int(p_job.frames)
	result.baseline_frames = int(baseline.get("frames", 0))
	if baseline.get("watch", []) != p_job.watch:
		result.watch_changed = {"baseline": baseline.get("watch", []), "current": p_job.watch}
	p_body.replay = result


# Physics queries run before the sample and before the checks of the same frame: this frame's
# ray then shows up in the sample, and an assertion on it is not one frame behind.
func _run_queries(p_offset: int) -> void:
	if _context.queries.is_empty():
		return
	var scheduled: Array = _context.queries.get(p_offset, [])
	if scheduled.is_empty():
		return
	for raw: Variant in scheduled:
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var row: Dictionary = SpaceQuery.run(_context, raw)
		row["at"] = p_offset
		_context.query_results[str(row.get("as", "query"))] = row
		_context.results.append(row)


# Assertions scheduled for this offset run at the same moment, and under the same offset, as a
# sample of that offset: one frame of game logic, then every question about it is answered.
func _run_checks(p_offset: int) -> void:
	if _context.checks.is_empty():
		return
	var scheduled: Array = _context.checks.get(p_offset, [])
	if scheduled.is_empty():
		return
	for row: Dictionary in Check.run(scheduled, _context, p_offset):
		_context.results.append(row)


# Plan entries whose "at" is past the last frame of this step never run: they are dropped when
# the plan is applied. Saying so beats a step that silently does less than asked for.
func _note_dropped_actions(p_plan: Array, p_frames: int) -> void:
	for entry: Variant in p_plan:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var at: int = int((entry as Dictionary).get("at", -1))
		if at >= 0 and at < p_frames:
			continue
		_context.results.append({
			"kind": "plan", "at": at, "dropped": true,
			"error": "this step runs %d frames, so offset %d never happens" % [p_frames, at],
		})


# Sample offsets relative to this step; defaults to the last frame only. An offset this step
# cannot reach is reported like a dropped plan entry, instead of quietly sampling less.
func _sample_offsets(p_payload: Dictionary, p_frames: int) -> Array:
	var raw: Array = p_payload.get("samples", [])
	if raw.is_empty():
		return [p_frames - 1]
	var out: Array = []
	for v: Variant in raw:
		var i: int = int(v)
		if i >= 0 and i < p_frames:
			out.append(i)
			continue
		_context.results.append({"kind": "plan", "sample": i, "dropped": true,
			"error": "this step runs %d frames, so sample offset %d never happens" % [p_frames, i]})
	return out
