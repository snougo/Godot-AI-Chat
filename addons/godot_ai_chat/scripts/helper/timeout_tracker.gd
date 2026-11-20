class_name TimeoutTracker
extends RefCounted

## 阶段与职责分离的超时检测器
##
## 采用「线程所有权分离」设计，无需 Mutex 锁：
## 1. 工作线程（StreamRequest._thread_task）仅在连接与等待响应头阶段使用
##    restart_connect_timer() / check_connect_or_header_timeout()；
## 2. 主线程看门狗独占使用 start_main_thread_watchdog() / mark_progress() /
##    check_main_thread_watchdog()，监控「业务层有效增量（LLMStreamDelta）停顿超时」
##    与「单次流式请求绝对墙钟上限」。


# --- Constants ---

## 最小有效超时阈值（秒）
const MIN_TIMEOUT_S: int = 30
## 单次流式请求绝对墙钟上限的最小兜底秒数（15 分钟）
const MIN_ABSOLUTE_TIMEOUT_S: int = 900
## 绝对墙钟上限相对于单阶段超时的倍数
const ABSOLUTE_TIMEOUT_MULTIPLIER: int = 5


# --- Private Vars ---

# 阶段预算（毫秒）
var _first_response_timeout_ms: int = 180000
var _progress_timeout_ms: int = 180000
var _absolute_timeout_ms: int = 900000

# [工作线程独占] 连接与请求响应头阶段的起始时间（毫秒）
var _worker_connect_start_msec: int = 0

# [主线程独占] 请求启动时间与最近一次收到有效业务增量（LLMStreamDelta）的时间（毫秒）
var _main_request_start_msec: int = 0
var _main_last_progress_msec: int = 0


# --- Built-in Functions ---

## [param p_first_response_timeout_s]: 连接 + 等待首包/有效产出的超时（秒）
## [param p_progress_timeout_s]: 流式过程中无实质内容产出的停顿超时（秒）
## [param p_absolute_timeout_s]: 单次请求绝对墙钟上限（秒）
func _init(p_first_response_timeout_s: float, p_progress_timeout_s: float, p_absolute_timeout_s: float = 0.0) -> void:
	var first_s: float = maxf(p_first_response_timeout_s, float(MIN_TIMEOUT_S))
	var progress_s: float = maxf(p_progress_timeout_s, float(MIN_TIMEOUT_S))
	var abs_s: float = p_absolute_timeout_s
	if abs_s <= 0.0:
		abs_s = maxf(progress_s * float(ABSOLUTE_TIMEOUT_MULTIPLIER), float(MIN_ABSOLUTE_TIMEOUT_S))
	
	_first_response_timeout_ms = int(first_s * 1000.0)
	_progress_timeout_ms = int(progress_s * 1000.0)
	_absolute_timeout_ms = int(abs_s * 1000.0)
	
	var now: int = Time.get_ticks_msec()
	_worker_connect_start_msec = now
	_main_request_start_msec = now
	_main_last_progress_msec = now


# --- Public Functions ---

## 从单个 network_timeout 设置值派生三层预算
static func from_network_timeout(p_timeout_s: int) -> TimeoutTracker:
	var safe_s: int = maxi(p_timeout_s, MIN_TIMEOUT_S)
	var abs_s: int = maxi(safe_s * ABSOLUTE_TIMEOUT_MULTIPLIER, MIN_ABSOLUTE_TIMEOUT_S)
	return new(float(safe_s), float(safe_s), float(abs_s))


## [工作线程] 在 JSON 序列化等耗时预处理完成后重新起表
func restart_phase_timer() -> void:
	_worker_connect_start_msec = Time.get_ticks_msec()


## [工作线程] 检查连接或等待 HTTP 响应头阶段是否超时
## 返回: { "timed_out": bool, "elapsed_ms": int, "timeout_ms": int }
func check() -> Dictionary:
	var elapsed: int = Time.get_ticks_msec() - _worker_connect_start_msec
	return {
		"timed_out": elapsed > _first_response_timeout_ms,
		"elapsed_ms": elapsed,
		"timeout_ms": _first_response_timeout_ms
	}


## 获取单阶段超时阈值（毫秒）
func get_current_timeout_ms() -> int:
	return _progress_timeout_ms


## [主线程] 启动主线程看门狗计时器（在 StreamRequest.start() 时调用）
func start_main_thread_watchdog() -> void:
	var now: int = Time.get_ticks_msec()
	_main_request_start_msec = now
	_main_last_progress_msec = now


## [主线程] 记录收到一次有实质业务产出的 LLMStreamDelta，续期 progress 计时器
func mark_progress() -> void:
	_main_last_progress_msec = Time.get_ticks_msec()


## [主线程] 每帧检查是否发生业务停顿超时或绝对墙钟超时
## [return]: 未超时返回空字符串；超时返回具体错误原因描述
func check_main_thread_watchdog() -> String:
	var now: int = Time.get_ticks_msec()
	var silent_ms: int = now - _main_last_progress_msec
	if silent_ms > _progress_timeout_ms:
		return "Request timed out: No meaningful model output received for %d seconds." % (_progress_timeout_ms / 1000)
	
	var total_ms: int = now - _main_request_start_msec
	if _absolute_timeout_ms > 0 and total_ms > _absolute_timeout_ms:
		return "Request timed out: Exceeded maximum total stream duration of %d seconds." % (_absolute_timeout_ms / 1000)
	
	return ""
