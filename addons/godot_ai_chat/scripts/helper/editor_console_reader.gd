class_name EditorConsoleReader
extends RefCounted

## 编辑器控制台读取器
##
## 引擎真值访问编辑器的 Output 面板与 Debugger Errors 标签页——直接读取用户正在看的控件。
## 面板通过类指纹定位（内部 C++ 类，脚本无法指名），停靠布局变化不会让读取失效；
## 面板找不到时诚实报错，绝不假装空控制台。所有方法均为静态。

# --- Constants ---

## 默认返回的最新输出行数
const DEFAULT_OUTPUT_LINES: int = 40
## 默认返回的最新错误条目数
const DEFAULT_ERROR_LIMIT: int = 10
## 单行最大中继长度，超出部分折叠为计数，防止单行刷屏
const MAX_LINE_CHARS: int = 400
## 每个错误条目最多中继的详情行数（引擎错误、源码行、栈帧）
const MAX_ERROR_DETAIL_ROWS: int = 12
## 面板消息类型过滤按钮的 EditorSettings 持久化键（4.7 MessageType 顺序）：
## 被关闭的类型会从面板文本中整体消失，不披露就会把"被阉割的面板"当成全量日志
const OUTPUT_FILTER_SETTINGS: Array = [
	[1, "Errors"], [3, "Warnings"], [0, "Standard Messages"],
	[4, "Editor Messages"], [2, "Rich Standard Messages"],
]


# --- Public Functions ---

## 读取 Output 面板最新 N 行；p_filter 非空时仅返回包含该子串的行；p_lines <= 0 使用默认值
static func read_output(p_lines: int = 0, p_filter: String = "") -> String:
	if not Engine.is_editor_hint():
		return "Error: the Output console exists only inside the editor UI, and this session is running headless — there is no panel to read."
	var label := output_label()
	if label == null:
		return "Error: the Output panel's log could not be located in this editor build — its internal layout may have changed. The read_output tool needs updating for this editor version."
	return _format_output(label.get_parsed_text(), p_lines, p_filter) + _output_hidden_note()


## 读取 Debugger Errors 标签页最新 N 条（多会话合并输出）；p_filter 非空时过滤
static func read_errors(p_limit: int = 0, p_filter: String = "") -> String:
	if not Engine.is_editor_hint():
		return "Error: the debugger's error history exists only inside the editor UI, and this session is running headless — there is no panel to read."
	var sessions := _error_trees()
	if sessions.is_empty():
		return "Error: the debugger's Errors list could not be located in this editor build — its internal layout may have changed. The read_errors tool needs updating for this editor version."
	var blocks: Array = []
	for session in sessions:
		var body := _format_errors(_error_entries(session["tree"]), p_limit, p_filter)
		if sessions.size() > 1:
			body = "%s:\n%s" % [session["session"], body]
		blocks.append(body)
	return "\n\n".join(PackedStringArray(blocks))


## 获取 Output 面板日志控件（EditorLog 内的 RichTextLabel）；找不到返回 null
## （read_output 与 run_editor_script 的编译错误捕获共用）
static func output_label() -> RichTextLabel:
	if not Engine.is_editor_hint():
		return null
	for panel in _find_by_class(EditorInterface.get_base_control(), "EditorLog"):
		for label in _find_by_class(panel, "RichTextLabel"):
			return label as RichTextLabel
	return null


## 从 Output 面板文本的 before/after 增量中提取编译/解析错误行
## （run_editor_script 捕获编译错误用；过滤"Parse/Compile Error/SCRIPT ERROR"及缩进详情行）
static func capture_error_delta(p_before: String, p_after: String) -> String:
	var new_text: String = ""
	if p_after.length() > p_before.length():
		new_text = p_after.substr(p_before.length())
	elif p_before.is_empty():
		new_text = p_after
	
	new_text = new_text.strip_edges()
	if new_text.is_empty():
		return ""
	
	var lines: PackedStringArray = new_text.split("\n")
	var filtered: PackedStringArray = []
	for line in lines:
		var trimmed: String = line.strip_edges()
		if trimmed.is_empty():
			continue
		if "Parse Error" in trimmed \
		or "Parse error" in trimmed \
		or "Compile Error" in trimmed \
		or "SCRIPT ERROR" in trimmed \
		or trimmed.begins_with("  ") \
		or trimmed.begins_with("at:"):
			filtered.append(trimmed)
	
	if filtered.is_empty():
		return new_text
	return "\n".join(filtered)


# --- 纯格式化（与面板访问分离，便于无头测试） ---

# 纯格式化：Output 文本 → 最新 N 行（裁剪），含头部统计
static func _format_output(p_text: String, p_lines: int, p_filter: String) -> String:
	var all: Array = _output_lines(p_text)
	if all.is_empty():
		return "The Output console is currently empty — nothing has been printed since it was last cleared."
	var cap: int = p_lines if p_lines > 0 else DEFAULT_OUTPUT_LINES
	var pool: Array = all
	if p_filter != "":
		var needle: String = p_filter.to_lower()
		pool = all.filter(func(line: Variant) -> bool: return String(line).to_lower().contains(needle))
		if pool.is_empty():
			return "Output console: %d lines; none contain \"%s\"." % [all.size(), p_filter]
	var shown: Array = pool.slice(maxi(0, pool.size() - cap))
	var body: Array = []
	for line in shown:
		body.append(_clip_line(String(line)))
	return "%s\n%s" % [_output_header(all.size(), pool.size(), shown.size(), p_filter), "\n".join(PackedStringArray(body))]


# 纯格式化：错误条目数组 → 文本
static func _format_errors(p_entries: Array, p_limit: int, p_filter: String) -> String:
	if p_entries.is_empty():
		return "The debugger's error history is empty: no errors or warnings have been recorded from running the project (nothing has run, or the user cleared it). Errors raised inside the editor itself land in the Output console instead — read_output shows those."
	var cap: int = p_limit if p_limit > 0 else DEFAULT_ERROR_LIMIT
	var errors: int = 0
	for entry: Dictionary in p_entries:
		if String(entry["kind"]) == "error":
			errors += 1
	var pool: Array = p_entries
	if p_filter != "":
		var needle: String = p_filter.to_lower()
		pool = p_entries.filter(func(entry: Variant) -> bool: return _entry_text(entry).to_lower().contains(needle))
		if pool.is_empty():
			return "Debugger error history: %d entries (%d errors, %d warnings); none contain \"%s\"." % [p_entries.size(), errors, p_entries.size() - errors, p_filter]
	var shown: Array = pool.slice(maxi(0, pool.size() - cap))
	var body: Array = []
	for entry: Dictionary in shown:
		body.append(_format_entry(entry))
	return "%s\n%s" % [_errors_header(p_entries.size(), errors, pool.size(), shown.size(), p_filter), "\n".join(PackedStringArray(body))]


# 从 Errors 标签页的 Tree 提取错误条目数组
static func _error_entries(p_tree: Tree) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var root: TreeItem = p_tree.get_root()
	if root == null:
		return out
	var item: TreeItem = root.get_first_child()
	while item != null:
		var detail: Array = []
		var child: TreeItem = item.get_first_child()
		while child != null:
			detail.append(("%s %s" % [child.get_text(0), child.get_text(1)]).strip_edges())
			child = child.get_next()
		out.append({
			"kind": "warning" if item.has_meta("_is_warning") else "error",
			"time": item.get_text(0),
			"title": item.get_text(1),
			"detail": detail,
		})
		item = item.get_next()
	return out


# 分割行并去掉尾部空行
static func _output_lines(p_text: String) -> Array:
	var all: Array = Array(p_text.split("\n"))
	while not all.is_empty() and String(all[all.size() - 1]).strip_edges() == "":
		all.remove_at(all.size() - 1)
	return all


# --- 头部统计 ---

static func _output_header(p_total: int, p_matched: int, p_shown: int, p_filter: String) -> String:
	if p_filter == "":
		if p_shown == p_total:
			return "Output console (%d lines):" % p_total
		return "Output console: %d lines total, showing the newest %d (raise \"lines\", or pass \"filter\" to reach older ones by content):" % [p_total, p_shown]
	if p_shown == p_matched:
		return "Output console: %d lines total; %d contain \"%s\":" % [p_total, p_matched, p_filter]
	return "Output console: %d lines total; %d contain \"%s\", showing the newest %d of those (raise \"lines\", or narrow the filter):" % [p_total, p_matched, p_filter, p_shown]


static func _errors_header(p_total: int, p_errors: int, p_matched: int, p_shown: int, p_filter: String) -> String:
	var tally := "%d entries (%d errors, %d warnings)" % [p_total, p_errors, p_total - p_errors]
	if p_filter == "":
		if p_shown == p_total:
			return "Debugger error history, %s, oldest first:" % tally
		return "Debugger error history, %s, showing the newest %d (oldest of those first — raise \"limit\", or pass \"filter\" to reach older entries by content):" % [tally, p_shown]
	if p_shown == p_matched:
		return "Debugger error history, %s; %d contain \"%s\":" % [tally, p_matched, p_filter]
	return "Debugger error history, %s; %d contain \"%s\", showing the newest %d of those (raise \"limit\", or narrow the filter):" % [tally, p_matched, p_filter, p_shown]


# --- 条目格式化 ---

static func _format_entry(p_entry: Dictionary) -> String:
	var rows: Array = ["[%s] %s: %s" % [p_entry["time"], String(p_entry["kind"]).to_upper(), _clip_line(String(p_entry["title"]))]]
	var detail: Array = p_entry["detail"]
	for i in mini(detail.size(), MAX_ERROR_DETAIL_ROWS):
		rows.append("  %s" % _clip_line(String(detail[i])))
	if detail.size() > MAX_ERROR_DETAIL_ROWS:
		rows.append("  (+%d more detail rows)" % (detail.size() - MAX_ERROR_DETAIL_ROWS))
	return "\n".join(PackedStringArray(rows))


static func _entry_text(p_entry_v: Variant) -> String:
	var entry: Dictionary = p_entry_v
	return "%s %s %s %s" % [entry["time"], entry["kind"], entry["title"], " ".join(PackedStringArray(entry["detail"]))]


static func _clip_line(p_line: String) -> String:
	if p_line.length() <= MAX_LINE_CHARS:
		return p_line
	return "%s… (+%d more chars)" % [p_line.left(MAX_LINE_CHARS), p_line.length() - MAX_LINE_CHARS]


# --- 面板定位（类指纹） ---

# 递归查找指定引擎类名的节点（面板类是脚本无法指名的内部 C++ 类，含 internal 子节点）
static func _find_by_class(p_root: Node, p_cls: String) -> Array[Node]:
	var found: Array[Node] = []
	var stack: Array[Node] = [p_root]
	while not stack.is_empty():
		var node: Node = stack.pop_back()
		for child in node.get_children(true):
			stack.append(child)
		if node.get_class() == p_cls:
			found.append(node)
	return found


# Errors 标签页的 Tree（每调试会话一个）：按形状指纹定位——TabContainer 下
# 直接挂 VBoxContainer，内含两列 Tree
static func _error_trees() -> Array[Dictionary]:
	var found: Array[Dictionary] = []
	for debugger in _find_by_class(EditorInterface.get_base_control(), "EditorDebuggerNode"):
		for session in _find_by_class(debugger, "ScriptEditorDebugger"):
			var tree := _session_error_tree(session)
			if tree != null:
				found.append({"session": String(session.name), "tree": tree})
	return found


static func _session_error_tree(p_session: Node) -> Tree:
	for tabs in p_session.get_children(true):
		if not tabs is TabContainer:
			continue
		for tab in tabs.get_children(true):
			if tab.get_class() != "VBoxContainer":
				continue
			for child in tab.get_children(true):
				if child is Tree and child.columns == 2:
					return child as Tree
	return null


# --- 视图控件披露 ---

# 披露面板自身视图控件对可见内容的限制（过滤按钮 + 搜索框），否则"空面板"就是谎言
static func _output_hidden_note() -> String:
	var hidden: Array = []
	var settings := EditorInterface.get_editor_settings()
	for entry: Array in OUTPUT_FILTER_SETTINGS:
		var key := "_editor_log_filter_%d" % int(entry[0])
		if settings.has_setting(key) and not bool(settings.get_setting(key)):
			hidden.append(String(entry[1]))
	
	var parts: Array = []
	if not hidden.is_empty():
		parts.append("the %s filter button(s) are toggled off, so those message types are missing from the panel and from this read" % " and ".join(PackedStringArray(hidden)))
	var search := _output_search_text()
	if search != "":
		parts.append("its search box is set to \"%s\", so only lines matching that are readable" % search)
	if parts.is_empty():
		return ""
	
	return "\n\nNote: the Output panel's own view controls are limiting what it shows — %s. If you need what's hidden, ask the user to reset those controls in the Output panel." % "; ".join(PackedStringArray(parts))


# 抓取 Output 面板搜索框文本（会话级，无设置持久化）
static func _output_search_text() -> String:
	for panel in _find_by_class(EditorInterface.get_base_control(), "EditorLog"):
		for box in _find_by_class(panel, "LineEdit"):
			return (box as LineEdit).text.strip_edges()
	return ""
