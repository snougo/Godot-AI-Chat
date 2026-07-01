class_name TimeoutTracker
extends RefCounted

## 阶段感知的超时检测器
##
## 管理两阶段超时：等待首token → 流式接收
## 纯计算组件，不依赖场景树，线程/主线程通用。

# --- Enums ---

enum Phase {
	WAITING_FIRST_TOKEN,  ## 等待首token阶段（连接+请求+等首数据）
	STREAMING             ## 流式接收阶段（停顿超时）
}

# --- Private Vars ---

var _phase: Phase = Phase.WAITING_FIRST_TOKEN
var _phase_start_time: int = 0

var _first_token_timeout_ms: int
var _stall_timeout_ms: int


# --- Built-in Functions ---

## [param p_first_token_timeout_s]: 等待首token超时（秒）
## [param p_stall_timeout_s]: 流中停顿超时（秒）
func _init(p_first_token_timeout_s: float, p_stall_timeout_s: float) -> void:
	_first_token_timeout_ms = int(p_first_token_timeout_s * 1000)
	_stall_timeout_ms = int(p_stall_timeout_s * 1000)
	_phase_start_time = Time.get_ticks_msec()


# --- Public Functions ---

## 从单个 network_timeout 值派生两阶段超时
static func from_network_timeout(p_timeout_s: int) -> TimeoutTracker:
	var first_token: float = p_timeout_s
	var stall: float = maxi(p_timeout_s / 1, 30)
	return new(first_token, stall)


## 标记首token到达，切换到 STREAMING 阶段并重置计时
func mark_first_token_received() -> void:
	_phase = Phase.STREAMING
	_phase_start_time = Time.get_ticks_msec()


## 标记收到流式数据，重置 STREAMING 阶段计时
func mark_data_received() -> void:
	_phase_start_time = Time.get_ticks_msec()


## 检查当前阶段是否超时
## 返回: {timed_out: bool, phase: Phase, elapsed_ms: int, timeout_ms: int}
func check() -> Dictionary:
	var elapsed: int = Time.get_ticks_msec() - _phase_start_time
	var timeout_ms: int = _get_current_timeout()
	return {
		"timed_out": elapsed > timeout_ms,
		"phase": _phase,
		"elapsed_ms": elapsed,
		"timeout_ms": timeout_ms
	}


## 获取当前阶段超时值（毫秒）
func get_current_timeout_ms() -> int:
	return _get_current_timeout()


## 获取当前阶段
func get_current_phase() -> Phase:
	return _phase


# --- Private Functions ---

func _get_current_timeout() -> int:
	match _phase:
		Phase.WAITING_FIRST_TOKEN:
			return _first_token_timeout_ms
		Phase.STREAMING:
			return _stall_timeout_ms
	return 0
