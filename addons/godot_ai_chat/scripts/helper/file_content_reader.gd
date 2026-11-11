extends RefCounted

# 文件内容读取器
#
# 负责把磁盘上的文件转成可直接喂给模型的 Markdown 文本。
# 对超过字符预算（MAX_OUTPUT_CHARS）的内容做分层压缩，避免网格 / 几何缓冲等
# 无意义数据撑爆上下文，同时保证结构性信息不被误伤：
#
# 1. 数值块省略：Packed*Array(...) 这类长数值字面量在原位替换为
#    "…N values elided…"，属性名、类型、元素个数全部保留。
# 2. 超长单行截头：只保留前 LONG_LINE_HEAD_CHARS 个字符，并标注省略的字符数。
# 3. 按行截尾：断点处留标记，写明被省略的行号区间与续读方式
#    （read_file 的 start_line / line_count 参数），保证截断不是死路。
#
# 压缩只在超预算时发生：未超预算时输出与旧实现完全一致（零噪音）。


# --- Constants ---

# 单次读取返回的字符预算（约 8k tokens 的代码量）
const MAX_OUTPUT_CHARS: int = 30000

# 为标题行 / 压缩说明预留的空间，正文预算 = MAX_OUTPUT_CHARS - 此值
const OUTPUT_RESERVE_CHARS: int = 600

# 单行长度上限，超出即截头
const MAX_SINGLE_LINE_CHARS: int = 1200

# 超长行截头后保留的字符数
const LONG_LINE_HEAD_CHARS: int = 800

# 单个区段头显示的最大字符数（超出后按空格回退截断）
const MAX_SECTION_HEADER_CHARS: int = 90

# 数值块被省略的最小字符长度与最小元素数（低于任一阈值视为有语义的小数据，原样保留）
const MIN_ELIDE_CHARS: int = 80
const MIN_ELIDE_VALUES: int = 16

# 省略区间段落索引的最大条目数（避免索引本身吃掉预算）
const MAX_SECTION_HEADERS: int = 8

# "Packed" 到 "(" 之间允许的最大字符数，超出说明不是 Packed 数组字面量
const PACKED_TYPE_MAX_CHARS: int = 40

# 小数组成员原样展示的最大元素数（超过后只报类型与元素个数）
const SMALL_PACKED_PREVIEW_ITEMS: int = 8

# 截断时头部保留的预算比例（其余留给尾部）
const HEAD_KEEP_RATIO: float = 0.6

# 截断断点向段落边界对齐时的搜索窗口（字符）；只对齐到更内侧，绝不超出预算
const BOUNDARY_SNAP_WINDOW: int = 1500

# 需要按"只报元素个数"处理的 Packed 数组类型
const PACKED_ARRAY_TYPES: Array[int] = [
	TYPE_PACKED_BYTE_ARRAY,
	TYPE_PACKED_INT32_ARRAY,
	TYPE_PACKED_INT64_ARRAY,
	TYPE_PACKED_FLOAT32_ARRAY,
	TYPE_PACKED_FLOAT64_ARRAY,
	TYPE_PACKED_STRING_ARRAY,
	TYPE_PACKED_VECTOR2_ARRAY,
	TYPE_PACKED_VECTOR3_ARRAY,
	TYPE_PACKED_VECTOR4_ARRAY,
	TYPE_PACKED_COLOR_ARRAY,
]


#  --- 场景树读取 ---

static func read_scene_content(p_path: String, p_start_line: int = 1, p_line_count: int = 0) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	# .tscn 是文本格式场景，复用文本读取逻辑直接返回文件内容
	if p_path.get_extension().to_lower() == "tscn":
		return read_text_content(p_path, p_start_line, p_line_count)
	
	# .scn 二进制场景：基于 SceneState 读取元信息（无需实例化，无副作用）
	var scene_resource: PackedScene = load(p_path)
	if not scene_resource:
		return {"success": false, "data": "Error: Failed to load scene: " + p_path}
	
	var state: SceneState = scene_resource.get_state() as SceneState
	if not state:
		return {"success": false, "data": "Error: Failed to get scene state: " + p_path}
	
	# [性能] 节点/连接数量可达数千，旧实现用 md += ... 逐个拼接，
	# GDScript 的 String += 会复制整个已累积字符串（O(n²)）。改为收集后一次 join。
	var parts: PackedStringArray = PackedStringArray()
	parts.append("- **Type**: %s" % scene_resource.get_class())
	parts.append("- **Path**: `%s`" % scene_resource.resource_path)
	parts.append("- **Can Instantiate**: %s" % str(scene_resource.can_instantiate()))
	
	# 继承的基场景
	var base_state: SceneState = state.get_base_scene_state()
	if base_state:
		parts.append("- **Base Scene**: `%s`" % base_state.get_path())
	
	# 节点列表
	var node_count: int = state.get_node_count()
	parts.append("")
	parts.append("**Nodes:** (%d)" % node_count)
	for i in range(node_count):
		parts.append(_format_scene_state_node(state, i))
	
	# 信号连接
	var conn_count: int = state.get_connection_count()
	parts.append("")
	parts.append("**Connections:** (%d)" % conn_count)
	for i in range(conn_count):
		parts.append(_format_scene_state_connection(state, i))
	
	var compacted: Dictionary = _compact_summary_body("".join(parts))
	return {"success": true, "data": _build_output("Content for Scene: `%s`" % p_path.get_file(), compacted, "")}


# 格式化 SceneState 中的单个节点：路径、类型、子场景实例、组、导出/覆写属性
# [param p_state]: 场景状态
# [param p_idx]: 节点索引
# [return]: Markdown 格式的节点信息
static func _format_scene_state_node(p_state: SceneState, p_idx: int) -> String:
	var md: String = "- `%s` [%s]" % [p_state.get_node_path(p_idx), p_state.get_node_type(p_idx)]
	
	var instance: PackedScene = p_state.get_node_instance(p_idx)
	if instance:
		md += " [instance: `%s`]" % instance.resource_path
	elif p_state.is_node_instance_placeholder(p_idx):
		md += " [placeholder: `%s`]" % p_state.get_node_instance_placeholder(p_idx)
	
	var groups: PackedStringArray = p_state.get_node_groups(p_idx)
	if not groups.is_empty():
		md += " [groups: %s]" % ", ".join(groups)
	
	md += "\n"
	
	var prop_count: int = p_state.get_node_property_count(p_idx)
	for pi in range(prop_count):
		var pname: StringName = p_state.get_node_property_name(p_idx, pi)
		var pvalue: Variant = p_state.get_node_property_value(p_idx, pi)
		md += "  - **%s**: %s\n" % [pname, _format_property_value(pvalue)]
	
	return md


# 格式化 SceneState 中的单个信号连接：源/信号/目标/方法，附 flags 与 binds
# [param p_state]: 场景状态
# [param p_idx]: 连接索引
# [return]: Markdown 格式的连接信息
static func _format_scene_state_connection(p_state: SceneState, p_idx: int) -> String:
	var md: String = "- `%s.%s` -> `%s.%s`" % [
		p_state.get_connection_source(p_idx),
		p_state.get_connection_signal(p_idx),
		p_state.get_connection_target(p_idx),
		p_state.get_connection_method(p_idx)
	]
	var extras: Array[String] = []
	var flags: int = p_state.get_connection_flags(p_idx)
	if flags != 0:
		extras.append("flags=%d" % flags)
	var binds: Array = p_state.get_connection_binds(p_idx)
	if not binds.is_empty():
		extras.append("binds=%s" % binds)
	if not extras.is_empty():
		md += " (%s)" % ", ".join(extras)
	return md + "\n"


#  --- 脚本读取 ---

static func read_script_content(p_path: String, p_start_line: int = 1, p_line_count: int = 0) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var source_code: String = ""
	if p_path.get_extension().to_lower() in ["gd", "gdshader"]:
		# .gd / .gdshader 一律直读磁盘：编辑器环境下 load() 会命中 ResourceCache 的旧资源实例
		# （文件被外部改写后不会自动重载），source_code 是过期内容。
		# 读文件必须反映磁盘真相，否则写工具的"成功"永远无法被验证。
		var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
		if not is_instance_valid(file):
			return {"success": false, "data": "Error: Failed to open file: " + p_path}
		source_code = file.get_as_text()
		file.close()
		if source_code.is_empty():
			return {"success": false, "data": "Error: File is empty: " + p_path}
	else:
		var resource: Resource = load(p_path)
		
		if resource is Script:
			if not resource.has_source_code():
				return {"success": false, "data": "Error: Script has no source code: " + p_path}
			source_code = resource.source_code
		elif resource is Shader:
			source_code = resource.get_code()
			if source_code.is_empty():
				return {"success": false, "data": "Error: Shader has no source code: " + p_path}
		else:
			var file2: FileAccess = FileAccess.open(p_path, FileAccess.READ)
			if not is_instance_valid(file2):
				return {"success": false, "data": "Error: Failed to open file: " + p_path}
			source_code = file2.get_as_text()
			file2.close()
			if source_code.is_empty():
				return {"success": false, "data": "Error: File is empty: " + p_path}
	
	var extension: String = p_path.get_extension().to_lower()
	var lang_tag: String = "gdscript"
	match extension:
		"gdshader", "gdshaderinc":  lang_tag = "gdshader"
		"glsl":                     lang_tag = "glsl"
	
	var window: Dictionary = _apply_line_window(source_code, p_start_line, p_line_count)
	var compacted: Dictionary = _prepare_body(window["text"], window, true)
	
	var md: String = "Content for Script: `%s`" % p_path.get_file()
	# md += _add_line_numbers(source_code)
	# 现在可以通过工具 ge_code_line_number 来精确获取代码行号了
	return {"success": true, "data": _build_output(md, compacted, lang_tag)}


#static func _add_line_numbers(p_source_code: String) -> String:
	#var lines: PackedStringArray = p_source_code.split("\n")
	#var line_number_width: int = max(3, str(lines.size()).length())
	#var result: String = ""
	#for i in range(lines.size()):
		#result += "%s | %s" % [str(i + 1).pad_zeros(line_number_width), lines[i]]
		#if i < lines.size() - 1:
			#result += "\n"
	#return result


#  --- 资源文件读取（.tres / .res） ---

static func read_resource_content(p_path: String, p_start_line: int = 1, p_line_count: int = 0) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var ext: String = p_path.get_extension().to_lower()
	
	# .tres 是纯文本，复用文本读取逻辑
	if ext == "tres":
		return read_text_content(p_path, p_start_line, p_line_count)
	
	# .res 是二进制，用 load() 取元信息
	var resource: Resource = load(p_path)
	if not resource:
		return {"success": false, "data": "Error: Failed to load resource: " + p_path}
	
	# [性能] 与场景读取同理：属性可能上千条，统一收集后一次 join
	var parts: PackedStringArray = PackedStringArray()
	parts.append("- **Type**: %s" % resource.get_class())
	parts.append("- **Path**: `%s`" % resource.resource_path)
	if not resource.resource_name.is_empty():
		parts.append("- **Name**: %s" % resource.resource_name)
	
	var has_props: bool = false
	for p in resource.get_property_list():
		if p.usage & PROPERTY_USAGE_SCRIPT_VARIABLE:
			if not has_props:
				parts.append("")
				parts.append("**Properties:**")
				has_props = true
			parts.append("- **%s**: %s" % [p.name, _format_property_value(resource.get(p.name))])
	
	var compacted: Dictionary = _compact_summary_body("".join(parts))
	return {"success": true, "data": _build_output("Content for Resource: `%s`" % p_path.get_file(), compacted, "")}


#  --- 文本文件读取 ---

static func read_text_content(p_path: String, p_start_line: int = 1, p_line_count: int = 0) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return {"success": false, "data": "Error: Failed to open file: " + p_path}
	var content: String = file.get_as_text()
	file.close()
	
	var extension: String = p_path.get_extension().to_lower()
	var is_json: bool = extension == "json"
	if is_json:
		var json: JSON = JSON.new()
		if json.parse(content) == OK:
			content = JSON.stringify(json.get_data(), "\t")
	
	var window: Dictionary = _apply_line_window(content, p_start_line, p_line_count)
	var compacted: Dictionary = _prepare_body(window["text"], window, true)
	# JSON 先被重新排版过，行号指向排版后的文本：必须明说，否则续读会错位
	if is_json and compacted["is_partial"]:
		var json_notices: Array[String] = compacted["notices"]
		json_notices.push_front("JSON was reformatted (tab-indented) before reading: line numbers refer to the reformatted text, not the raw file.")
		compacted["notices"] = json_notices
	
	var file_name: String = p_path.get_file()
	var header: String = "Content for File: `%s`" % file_name
	
	# txt / md 不加代码围栏，其余格式按扩展名推断语言标签
	if extension in ["txt", "md"]:
		return {"success": true, "data": _build_output(header, compacted, "")}
	
	var lang_tag: String = extension
	match extension:
		"godot", "import":  lang_tag = "ini"
	
	return {"success": true, "data": _build_output(header, compacted, lang_tag)}


#  --- 图片元数据读取 ---

static func read_image_metadata(p_path: String) -> Dictionary:
	if not FileAccess.file_exists(p_path):
		return {"success": false, "data": "Error: File not found: " + p_path}
	
	var supported_extensions: Array = ["png", "jpg", "jpeg", "svg"]
	var extension: String = p_path.get_extension().to_lower()
	if extension not in supported_extensions:
		return {"success": false, "data": "Error: Unsupported image format: " + extension}
	
	var texture: Texture2D = load(p_path)
	if not is_instance_valid(texture):
		return {"success": false, "data": "Error: Failed to load image: " + p_path}
	
	var file: FileAccess = FileAccess.open(p_path, FileAccess.READ)
	if not is_instance_valid(file):
		return {"success": false, "data": "Error: Failed to open image file: " + p_path}
	var file_size_bytes: int = file.get_length()
	file.close()
	
	var file_name: String = p_path.get_file()
	var md: String = "Context for Image: `%s`\n\n" % file_name
	md += "*   **Path**: `%s`\n" % p_path
	md += "*   **Dimensions**: %d x %d pixels\n" % [texture.get_width(), texture.get_height()]
	md += "*   **File Size**: %s\n" % _format_bytes(file_size_bytes)
	return {"success": true, "data": md}


#  --- 输出装配与压缩 ---

# 组装最终输出：首行标题 +（可选）[PARTIAL] 说明 + 正文（可选代码围栏）
# [param p_header]: 首行标题（如 "Content for File: `x.tscn`"）
# [param p_compacted]: _prepare_body() / _compact_summary_body() 的返回值
# [param p_fence]: 代码围栏语言标签，空字符串表示不加围栏
static func _build_output(p_header: String, p_compacted: Dictionary, p_fence: String) -> String:
	var notices: Array[String] = p_compacted["notices"]
	var is_partial: bool = p_compacted["is_partial"]
	var body: String = p_compacted["text"]
	
	var chunks: PackedStringArray = PackedStringArray()
	chunks.append(p_header + ("  [PARTIAL]" if is_partial else ""))
	if is_partial:
		# 把"内容不完整"放在最前面：模型读完首行就该知道这不是全量
		chunks.append("(Partial content — read the notes below before drawing conclusions about this file. Structural lines are never altered; every abbreviation is counted in place.)")
		for notice in notices:
			chunks.append("- " + notice)
	
	if p_fence.is_empty():
		chunks.append("")
		chunks.append(body)
	else:
		chunks.append("```" + p_fence)
		chunks.append(body)
		chunks.append("```")
	
	return "\n".join(chunks)


# 正文压缩与"部分内容"说明
# [param p_body]: 正文（行号与文件一致，或为生成式摘要）
# [param p_window]: _apply_line_window() 的返回值
# [param p_pageable]: 是否支持 start_line 续读（生成式摘要为 false）
# [return]: {text: String, notices: Array[String], is_partial: bool}
static func _prepare_body(p_body: String, p_window: Dictionary, p_pageable: bool) -> Dictionary:
	var notices: Array[String] = []
	var text: String = p_body
	var budget: int = MAX_OUTPUT_CHARS - OUTPUT_RESERVE_CHARS
	
	# 调用方主动请求的行窗口：这是"刻意的部分读取"，需要提前声明
	if p_window["windowed"]:
		notices.append("Lines %d-%d of %d requested (a deliberate window, not the whole file)." % [p_window["start"], p_window["end"], p_window["total"]])
	
	# 第 1 层：省略 Packed*Array 数值块（网格顶点 / 索引缓冲的主战场）
	if text.length() > budget:
		var elided: Dictionary = _elide_packed_arrays(text)
		if elided["blocks"] > 0:
			text = elided["text"]
			notices.append(_format_elide_notice(elided))
	
	# 第 2 层：超长单行截头（压成一行的 JSON、单行 base64 内嵌数据等）
	if text.length() > budget:
		var capped: Dictionary = _cap_long_lines(text)
		if capped["lines"] > 0:
			text = capped["text"]
			notices.append("%d over-long line(s) cut after %d chars (~%s elided)." % [capped["lines"], LONG_LINE_HEAD_CHARS, _format_bytes(capped["saved_chars"])])
	
	# 第 3 层：保留头尾、省略中间，断点处留标记 + 说明续读方式
	if text.length() > budget:
		var truncated: Dictionary = _truncate_body(text, budget, int(p_window["start"]), p_pageable)
		text = truncated["text"]
		notices.append(truncated["notice"])
	
	return {"text": text, "notices": notices, "is_partial": not notices.is_empty()}


# 压缩"生成式正文"（如 .scn / .res 的结构摘要：没有文件行号，也不支持行窗口续读）
static func _compact_summary_body(p_body: String) -> Dictionary:
	var total_lines: int = p_body.count("\n") + 1
	var window: Dictionary = {
		"text": p_body,
		"start": 1,
		"end": total_lines,
		"total": total_lines,
		"windowed": false,
	}
	return _prepare_body(p_body, window, false)


# 省略 Packed*Array(...) 数据块，原位替换为带计数的标记
# 只处理"单行内闭合"的形态，其余形态原样保留（交给后面的层处理）
# [return]: {text: String, blocks: int, values: int, blob_chars: int, saved_chars: int, type_counts: Dictionary}
static func _elide_packed_arrays(p_text: String) -> Dictionary:
	var chunks: PackedStringArray = PackedStringArray()
	var type_counts: Dictionary = {}
	var blocks: int = 0
	var values: int = 0
	var blob_chars: int = 0
	var saved_chars: int = 0
	var copy_from: int = 0
	var cursor: int = 0
	var text_len: int = p_text.length()
	
	while cursor < text_len:
		var start: int = p_text.find("Packed", cursor)
		if start == -1:
			break
		
		# 前置边界：不能是更长标识符的一部分（如 myPackedByteArray）
		if start > 0 and _is_ident_char(p_text.unicode_at(start - 1)):
			cursor = start + 1
			continue
		
		var open_paren: int = p_text.find("(", start)
		if open_paren == -1:
			break
		if open_paren - start > PACKED_TYPE_MAX_CHARS:
			cursor = start + 1
			continue
		if not _is_packed_type_name(p_text.substr(start, open_paren - start)):
			cursor = start + 1
			continue
		
		var close_paren: int = p_text.find(")", open_paren)
		if close_paren == -1:
			break
		
		var type_name: String = p_text.substr(start, open_paren - start)
		var run_len: int = close_paren + 1 - start
		var marker: String = ""
		var value_count: int = 0
		var blob_len: int = 0
		
		# 形态一：纯数值序列，如 PackedFloat32Array(0, 0, 1, ...)
		# 形态二：单个超长 base64 字符串，如 PackedByteArray("URKy...")
		#         文本序列化的网格 / 蒙皮数据绝大多数是这种形态，必须单独覆盖
		if _is_flat_value_run(p_text, open_paren + 1, close_paren):
			value_count = _count_values(p_text, open_paren + 1, close_paren)
			if run_len >= MIN_ELIDE_CHARS and value_count >= MIN_ELIDE_VALUES:
				marker = "%s(…%d values elided…)" % [type_name, value_count]
		else:
			blob_len = _quoted_blob_length(p_text, open_paren + 1, close_paren)
			if blob_len >= MIN_ELIDE_CHARS:
				marker = "%s(…%d base64 chars, ~%s of raw bytes, elided…)" % [type_name, blob_len, _format_bytes(blob_len * 3 / 4)]
		
		if marker.is_empty():
			cursor = close_paren + 1
			continue
		
		chunks.append(p_text.substr(copy_from, start - copy_from))
		chunks.append(marker)
		copy_from = close_paren + 1
		cursor = close_paren + 1
		
		blocks += 1
		values += value_count
		blob_chars += blob_len
		saved_chars += run_len - marker.length()
		type_counts[type_name] = int(type_counts.get(type_name, 0)) + 1
	
	chunks.append(p_text.substr(copy_from))
	
	return {
		"text": "".join(chunks),
		"blocks": blocks,
		"values": values,
		"blob_chars": blob_chars,
		"saved_chars": saved_chars,
		"type_counts": type_counts,
	}


# 超长单行截头：只保留前 LONG_LINE_HEAD_CHARS 个字符
# [return]: {text: String, lines: int, saved_chars: int}
static func _cap_long_lines(p_text: String) -> Dictionary:
	var lines: PackedStringArray = p_text.split("\n")
	var capped_lines: int = 0
	var saved_chars: int = 0
	
	for i in range(lines.size()):
		var line: String = lines[i]
		if line.length() <= MAX_SINGLE_LINE_CHARS:
			continue
		var removed: int = line.length() - LONG_LINE_HEAD_CHARS
		lines[i] = line.substr(0, LONG_LINE_HEAD_CHARS) + "…(+%d chars elided)…" % removed
		capped_lines += 1
		saved_chars += removed
	
	return {"text": "\n".join(lines), "lines": capped_lines, "saved_chars": saved_chars}


# 超预算截断：保留头尾、省略中间
# 场景 / 资源的"结构"集中在首尾（头部 ext_resource、尾部 [node] 与 [connection]），
# 只砍尾部会把最该看的节点树砍掉，因此头尾各留一部分。
# [param p_text]: 待截断正文
# [param p_budget]: 正文预算（字符）
# [param p_line_offset]: 正文首行在文件中的行号（1-based）
# [param p_pageable]: 正文是否来自文件原始文本（false 时为生成式摘要）
# [return]: {text: String, notice: String}
static func _truncate_body(p_text: String, p_budget: int, p_line_offset: int, p_pageable: bool) -> Dictionary:
	var total_lines: int = p_line_offset + p_text.count("\n")
	var head_budget: int = int(p_budget * HEAD_KEEP_RATIO)
	var head_cut: int = p_text.rfind("\n", head_budget)
	if head_cut <= 0:
		head_cut = head_budget
	# 断点对齐到段落边界，避免尾部从某个节点的属性中间开始
	head_cut = _snap_head_cut(p_text, head_cut)
	
	# 尾部预算 = 总预算 - 已用的头部；从后往前找行首，避免切断行
	var tail_budget: int = p_budget - head_cut
	var tail_start: int = p_text.length()
	if tail_budget > 0:
		var tail_newline: int = p_text.find("\n", p_text.length() - tail_budget)
		if tail_newline != -1:
			tail_start = tail_newline + 1
	tail_start = _snap_tail_start(p_text, tail_start)
	# 头尾重叠（正文过短或全是超长行）：退化为只保留头部
	if tail_start <= head_cut:
		tail_start = p_text.length()
	
	var head_text: String = p_text.substr(0, head_cut)
	var tail_text: String = p_text.substr(tail_start)
	var head_lines: int = head_text.count("\n") + 1
	var tail_lines: int = 0
	if not tail_text.is_empty():
		tail_lines = tail_text.count("\n") + 1
	
	var omitted_from: int = p_line_offset + head_lines
	var omitted_to: int = maxi(omitted_from, total_lines - tail_lines)
	var omitted_label: String = _format_bytes(tail_start - head_cut)
	var shown_lines: int = head_lines + tail_lines
	
	var text: String = head_text + "\n…\n[omitted: lines %d-%d, ~%s]\n…" % [omitted_from, omitted_to, omitted_label]
	if not tail_text.is_empty():
		text += "\n" + tail_text
	
	# 列出被省略区间内的区段头：避免"看不见就等于不存在"的误判
	var section_index: String = _index_section_headers(p_text.substr(head_cut, tail_start - head_cut))
	
	var notice: String
	if p_pageable:
		notice = "%d of %d file lines shown (first %d, last %d; ~%s omitted in the middle). Read the gap with read_file(path, start_line=%d, line_count=%d); to locate a specific symbol, prefer search_in_files over reading whole files." % [shown_lines, total_lines, head_lines, tail_lines, omitted_label, omitted_from, omitted_to - omitted_from + 1]
	else:
		notice = "%d of %d summary lines shown (first %d, last %d; ~%s omitted in the middle). This kind of file is summarised structurally only — narrow the question (e.g. read the parent scene or the referenced sub-resource) instead of reading it whole." % [shown_lines, total_lines, head_lines, tail_lines, omitted_label]
	
	if not section_index.is_empty():
		notice += " Sections inside the omitted range: %s." % section_index
	
	return {"text": text, "notice": notice}


# 按行裁剪正文（1-based，越界自动收敛）
# [param p_content]: 原始文本
# [param p_start_line]: 起始行
# [param p_line_count]: 读取行数（<= 0 表示读到末尾）
# [return]: {text: String, start: int, end: int, total: int, windowed: bool}
static func _apply_line_window(p_content: String, p_start_line: int, p_line_count: int) -> Dictionary:
	var lines: PackedStringArray = p_content.split("\n")
	var total: int = lines.size()
	var start: int = clampi(p_start_line, 1, maxi(total, 1))
	var end: int = total
	if p_line_count > 0:
		end = mini(start + p_line_count - 1, total)
	
	if start == 1 and end == total:
		return {"text": p_content, "start": 1, "end": total, "total": total, "windowed": false}
	
	return {
		"text": "\n".join(lines.slice(start - 1, end)),
		"start": start,
		"end": end,
		"total": total,
		"windowed": true,
	}


# 生成数据块省略说明（列出各类型被省略的块数与载荷规模）
static func _format_elide_notice(p_elided: Dictionary) -> String:
	var type_counts: Dictionary = p_elided["type_counts"]
	var type_names: Array = type_counts.keys()
	type_names.sort()
	var type_summary: PackedStringArray = PackedStringArray()
	for type_name in type_names:
		type_summary.append("%s ×%d" % [type_name, type_counts[type_name]])
	
	var payload: PackedStringArray = PackedStringArray()
	var value_count: int = int(p_elided["values"])
	if value_count > 0:
		payload.append("%d raw numeric value(s)" % value_count)
	var blob_total: int = int(p_elided["blob_chars"])
	if blob_total > 0:
		payload.append("~%s of base64 payload" % _format_bytes(blob_total * 3 / 4))
	
	return "%d data block(s) elided in place (%s; %s). Property names, element counts and every structural line are intact — the payloads themselves are not needed to read this file." % [
		p_elided["blocks"],
		", ".join(type_summary),
		", ".join(payload),
	]


#  --- 通用格式化 ---

static func _format_property_value(p_val: Variant) -> String:
	var type_id: int = typeof(p_val)
	
	# Packed 数组（网格顶点 / 索引缓冲等）只报类型与元素个数，绝不逐项展开
	if type_id in PACKED_ARRAY_TYPES:
		if p_val.size() <= SMALL_PACKED_PREVIEW_ITEMS:
			return str(p_val)
		return "[%s: %d items]" % [type_string(type_id), p_val.size()]
	
	match type_id:
		TYPE_STRING:
			return "\"%s\"" % p_val
		TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
			return str(p_val)
		TYPE_ARRAY:
			return "[Array: %d items]" % p_val.size()
		TYPE_DICTIONARY:
			return "[Dictionary: %d keys]" % p_val.size()
		TYPE_OBJECT:
			if p_val is Resource:
				return "[Resource: %s]" % p_val.resource_path.get_file()
			return str(p_val)
		_:
			return str(p_val)


static func _format_bytes(p_bytes: int) -> String:
	if p_bytes < 1024:
		return "%d B" % p_bytes
	elif p_bytes < 1024 * 1024:
		return "%.2f KB" % (p_bytes / 1024.0)
	elif p_bytes < 1024 * 1024 * 1024:
		return "%.2f MB" % (p_bytes / (1024.0 * 1024.0))
	else:
		return "%.2f GB" % (p_bytes / (1024.0 * 1024.0 * 1024.0))


#  --- 内部工具 ---

# 判断字符码是否为标识符字符（字母、数字、下划线）
static func _is_ident_char(p_code: int) -> bool:
	return (
		(p_code >= 0x30 and p_code <= 0x39)
		or (p_code >= 0x41 and p_code <= 0x5A)
		or (p_code >= 0x61 and p_code <= 0x7A)
		or p_code == 0x5F
	)


# 判断 "Packed" 到 "(" 之间的片段是否为 Packed 数组类型名（如 PackedFloat32Array）
static func _is_packed_type_name(p_name: String) -> bool:
	if p_name.length() > PACKED_TYPE_MAX_CHARS:
		return false
	if not p_name.begins_with("Packed") or not p_name.ends_with("Array"):
		return false
	for i in range(p_name.length()):
		if not _is_ident_char(p_name.unicode_at(i)):
			return false
	return true


# 判断括号内是否为"扁平数值序列"：不含引号 / 换行 / 嵌套括号或中括号
static func _is_flat_value_run(p_text: String, p_from: int, p_to: int) -> bool:
	for i in range(p_from, p_to):
		var code: int = p_text.unicode_at(i)
		if (
			code == 0x22 or code == 0x27 or code == 0x0A or code == 0x0D
			or code == 0x28 or code == 0x29 or code == 0x5B or code == 0x5D
			or code == 0x7B or code == 0x7D
		):
			return false
	return true


# 判断括号内是否为"单个超长字符串"（base64 载荷），返回其内容长度；不是则返回 0
static func _quoted_blob_length(p_text: String, p_from: int, p_to: int) -> int:
	if p_to - p_from < 2:
		return 0
	if p_text.unicode_at(p_from) != 0x22 or p_text.unicode_at(p_to - 1) != 0x22:
		return 0
	# 内部不允许再出现引号：出现说明是拼接 / 转义形态，不做处理
	var probe: int = p_text.find("\"", p_from + 1)
	if probe != -1 and probe < p_to - 1:
		return 0
	return p_to - p_from - 2


# 统计括号内以逗号分隔的元素个数
static func _count_values(p_text: String, p_from: int, p_to: int) -> int:
	if p_to <= p_from:
		return 0
	var count: int = 1
	var pos: int = p_from
	while true:
		var comma: int = p_text.find(",", pos)
		if comma == -1 or comma >= p_to:
			break
		count += 1
		pos = comma + 1
	return count


# 头部断点向内对齐：优先取最近的 "[section]" 行首，其次空行
static func _snap_head_cut(p_text: String, p_pos: int) -> int:
	var lower: int = maxi(0, p_pos - BOUNDARY_SNAP_WINDOW)
	var section: int = p_text.rfind("\n[", p_pos)
	if section != -1 and section >= lower:
		return section
	var blank: int = p_text.rfind("\n\n", p_pos)
	if blank != -1 and blank >= lower:
		return blank
	return p_pos


# 尾部起点向后对齐：优先取最近的 "[section]" 行首，其次空行之后
static func _snap_tail_start(p_text: String, p_pos: int) -> int:
	var limit: int = mini(p_text.length(), p_pos + BOUNDARY_SNAP_WINDOW)
	var best: int = -1
	var section: int = p_text.find("\n[", p_pos)
	if section != -1 and section + 1 <= limit:
		best = section + 1
	var blank: int = p_text.find("\n\n", p_pos)
	if blank != -1 and blank + 2 <= limit:
		var candidate: int = blank + 2
		if best == -1 or candidate < best:
			best = candidate
	return p_pos if best == -1 else best


# 收集一段文本里的区段头（形如 "[node name=...]"），返回用逗号连接的索引串
# 只认 "[小写标识符" 开头，排除 JSON / 代码里的数组字面量
# 排序策略：[node] 优先（场景结构主体），同类 sub_resource 只列一次
static func _index_section_headers(p_omitted: String) -> String:
	var node_headers: PackedStringArray = PackedStringArray()
	var other_headers: PackedStringArray = PackedStringArray()
	var seen_types: Dictionary = {}
	
	for line in p_omitted.split("\n"):
		if line.length() < 3 or not line.begins_with("["):
			continue
		var first: int = line.unicode_at(1)
		if not ((first >= 0x61 and first <= 0x7A) or first == 0x5F):
			continue
		
		# 节点是场景结构的主体，优先列出；同类 sub_resource 只列一次，
		# 否则几十条 AnimationNode* 会把 node 挤掉
		if line.begins_with("[node "):
			node_headers.append(_short_header(line))
			continue
		var type_key: String = _header_group_key(line)
		if seen_types.has(type_key):
			continue
		seen_types[type_key] = true
		other_headers.append(_short_header(line))
	
	var merged: PackedStringArray = PackedStringArray()
	merged.append_array(node_headers)
	merged.append_array(other_headers)
	if merged.size() > MAX_SECTION_HEADERS:
		merged.resize(MAX_SECTION_HEADERS)
		merged.append("…")
	return ", ".join(merged)


# 把区段头压到可读长度：按空格回退截断，绝不切在标识符中间
static func _short_header(p_line: String) -> String:
	if p_line.length() <= MAX_SECTION_HEADER_CHARS:
		return "`%s`" % p_line
	var cut: int = p_line.rfind(" ", MAX_SECTION_HEADER_CHARS)
	if cut <= 0:
		cut = MAX_SECTION_HEADER_CHARS
	return "`%s…`" % p_line.substr(0, cut)


# 区段头的去重键：sub_resource 按 type="..." 归并，其余按整行
static func _header_group_key(p_line: String) -> String:
	var type_pos: int = p_line.find("type=\"")
	if type_pos == -1:
		return p_line
	var type_end: int = p_line.find("\"", type_pos + 6)
	if type_end == -1:
		return p_line
	return p_line.substr(type_pos, type_end - type_pos + 1)
