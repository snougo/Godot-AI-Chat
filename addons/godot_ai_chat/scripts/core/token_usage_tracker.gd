@tool
class_name TokenUsageTracker
extends RefCounted

## Token 用量累计器
##
## 负责「当前请求」「上一轮请求」与「本会话已归档」三个层级的 Token 计数，
## 与任何 UI 控件解耦：UI 只负责读取数值并渲染，不参与计算。
##
## 计数规则：
## 1. 同一请求内多次上报时只增不减（部分 Provider 会分多次上报递增的用量）；
## 2. 新一轮请求发起前调用 archive_current()：把上一轮用量结算进会话总量，
##    同时把该轮快照保留为「上一轮」，供新一轮数据到达前回落展示。
##
## [为什么需要「上一轮」快照]
## 除 Anthropic 会在 message_start 立即下发 input_tokens 外，其余协议
## （Chat Completions 的 include_usage 尾块 / Responses 的 response.completed /
## Gemini 的 usageMetadata）都在**流末尾**才下发用量。若不保留快照，
## 整个生成期间展示区只会是 0 / 0 / 0。


# --- Constants ---

## 空用量模板
const EMPTY_USAGE: Dictionary = { "prompt": 0, "completion": 0, "total": 0 }


# --- Private Vars ---

## 本会话已归档的累计用量
var _archived: Dictionary = EMPTY_USAGE.duplicate()
## 当前请求的用量
var _current: Dictionary = EMPTY_USAGE.duplicate()
## 上一次已结算请求的用量快照（回落展示用）
var _last_round: Dictionary = EMPTY_USAGE.duplicate()


# --- Public Functions ---

## 结算当前请求：把其用量归入会话总量，并清零当前请求
func archive_current() -> void:
	_archived["prompt"] = int(_archived["prompt"]) + int(_current["prompt"])
	_archived["completion"] = int(_archived["completion"]) + int(_current["completion"])
	_archived["total"] = int(_archived["total"]) + int(_current["total"])
	
	# 仅在本次请求确实上报过用量时才刷新快照：
	# 否则失败或空响应的请求会把「上一轮」覆盖成全 0，回落展示失去意义
	if not _is_usage_empty(_current):
		_last_round = _current.duplicate()
	
	_current = EMPTY_USAGE.duplicate()


## 更新当前请求用量（只增不减，避免中途上报较小值导致显示回退）
## [param p_usage]: Provider 上报的用量，键为 prompt_tokens / completion_tokens / total_tokens
func update_current(p_usage: Dictionary) -> void:
	var prompt: int = int(p_usage.get("prompt_tokens", 0))
	var completion: int = int(p_usage.get("completion_tokens", 0))
	
	if prompt < int(_current["prompt"]):
		prompt = int(_current["prompt"])
	if completion < int(_current["completion"]):
		completion = int(_current["completion"])
	
	var total: int = int(p_usage.get("total_tokens", prompt + completion))
	
	_current = { "prompt": prompt, "completion": completion, "total": total }


## 重置全部计数（含「上一轮」快照，避免跨会话串数据）
func reset() -> void:
	_archived = EMPTY_USAGE.duplicate()
	_current = EMPTY_USAGE.duplicate()
	_last_round = EMPTY_USAGE.duplicate()


## 载入会话时注入其存档中的累计用量作为归档基线
## [param p_archived]: 存档中的累计用量 { "prompt": int, "completion": int, "total": int }
func load_archived(p_archived: Dictionary) -> void:
	_archived = {
		"prompt": int(p_archived.get("prompt", 0)),
		"completion": int(p_archived.get("completion", 0)),
		"total": int(p_archived.get("total", 0)),
	}
	
	_current = EMPTY_USAGE.duplicate()
	_last_round = EMPTY_USAGE.duplicate()


## 获取展示用的总量（会话累计 + 当前请求）
func get_display_total() -> int:
	return int(_archived["total"]) + int(_current["total"])


## 获取当前累计用量的完整快照（归档 + 当前请求），供调用方落库到会话存档
## [return]: { "prompt": int, "completion": int, "total": int }
func get_total_usage() -> Dictionary:
	return {
		"prompt": int(_archived["prompt"]) + int(_current["prompt"]),
		"completion": int(_archived["completion"]) + int(_current["completion"]),
		"total": int(_archived["total"]) + int(_current["total"]),
	}


## 获取用于展示的「当前 / 上一轮」用量
##
## 当前请求尚未上报任何数据时回落为上一轮快照，避免生成期间恒显示 0/0/0。
## [return]: { "prompt": int, "completion": int, "total": int }
func get_display_usage() -> Dictionary:
	if _is_usage_empty(_current):
		return _last_round.duplicate()
	return _current.duplicate()


## 展示数据是否来自「上一轮」快照（而非当前请求）
func is_showing_last_round() -> bool:
	return _is_usage_empty(_current) and not _is_usage_empty(_last_round)


## 获取会话累计用量 { "prompt": int, "completion": int, "total": int }
func get_archived() -> Dictionary:
	return _archived.duplicate()


# --- Private Functions ---

# 判断用量是否为「无数据」（三个维度全为 0）
static func _is_usage_empty(p_usage: Dictionary) -> bool:
	return (
		int(p_usage.get("total", 0)) == 0
		and int(p_usage.get("prompt", 0)) == 0
		and int(p_usage.get("completion", 0)) == 0
	)
