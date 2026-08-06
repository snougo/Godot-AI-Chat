class_name GDScriptTokenizer
extends RefCounted

## 字符级 GDScript 分词器，为安全静态分析提供可靠的词法基础。
##
## 设计目标：
## - 精确区分 代码 / 字符串 / 注释（含三引号、raw 字符串、StringName、
##   NodePath、转义引号、跨行字符串、行续接）；
## - 不构建 AST、不校验语法合法性，宽容式扫描；
## - 与安全策略解耦：本类只输出词法事实，是否拦截由消费方决定。

# ============================================================================
# Enums / Constants
# ============================================================================

enum TokenType {
	KEYWORD,      ## 关键字（if/for/var/self...）
	IDENTIFIER,   ## 标识符（含 @annotation、$Node 的 Node 部分）
	OPERATOR,     ## 运算符（含 :=、==、->、$、% 等）
	NUMBER,       ## 数字字面量
	STRING,       ## 字符串（含引号/前缀/转义原文，如 r"..."、&"..."）
	COMMENT,      ## 注释（# 到行尾）
	WHITESPACE,   ## 空格/制表符/回车
	NEWLINE,      ## 换行
	UNKNOWN,      ## 无法识别的字符（宽容跳过）
}

## GDScript 4 关键字表。
const KEYWORDS: Array[String] = [
	"if", "elif", "else", "for", "while", "match", "when",
	"func", "class", "extends", "var", "const", "signal", "class_name",
	"and", "or", "not", "true", "false", "null", "pass", "self", "super",
	"await", "in", "is", "as", "enum", "assert", "preload", "load",
	"static", "void", "tool", "onready", "export", "setget",
	"break", "continue", "return",
]

## 双字符运算符（先于单字符匹配）。
const TWO_CHAR_OPS: Array[String] = [
	"==", "!=", "<=", ">=", "&&", "||", "->", "::", "..",
	"+=", "-=", "*=", "/=", "%=", "**", "<<", ">>", ":=",
]

## 单字符运算符（$ 为节点路径简写，也在此列）。
const SINGLE_OPS: String = "+-*/%=<>!&|^~.,:?$()[]{}"

## 赋值左侧前一 token 命中这些值则视为"非变量赋值"（属性/参数/索引等）。
const NON_ASSIGNMENT_PREV: Array[String] = [".", "(", ",", "[", "{"]

## 语句头关键字，其后出现的 `=` 不作为变量赋值追踪。
const STATEMENT_KEYWORDS: Array[String] = [
	"if", "elif", "while", "match", "for",
	"return", "assert", "break", "continue", "pass", "class_name",
]

## RHS 首 token 命中这些关键字时不作为类型/引用记录。
const IGNORED_RHS_KEYWORDS: Array[String] = [
	"true", "false", "null", "func", "if", "for", "while", "match",
	"return", "self", "super", "await", "pass", "break", "continue",
]

# ============================================================================
# Public Functions
# ============================================================================

## 将源码切分为扁平 Token 流（含精确行列号）。
static func tokenize(p_code: String) -> Array[Token]:
	var engine := _Engine.new(p_code)
	return engine._run()


## 提取所有 `obj.method(` 形式的调用（含链式 `).method(`、`$Node.method(`）。
## 返回数组，每项: {object: String, method: String, line: int, column: int, args: Array[String]}
## args 为按 token 边界切分的参数原始文本（空格连接，含引号）。
static func extract_calls(p_code: String) -> Array[Dictionary]:
	var tokens := tokenize(p_code)
	var calls: Array[Dictionary] = []
	for i in tokens.size():
		var t: Token = tokens[i]
		if t.type != TokenType.OPERATOR or t.value != ".":
			continue
		# 前一个有效 token（对象）
		var k := i - 1
		while k >= 0 and tokens[k].type == TokenType.WHITESPACE:
			k -= 1
		if k < 0:
			continue
		var prev: Token = tokens[k]
		if prev.type != TokenType.IDENTIFIER and prev.type != TokenType.KEYWORD \
				and prev.value != ")" and prev.type != TokenType.STRING and prev.value != "]":
			continue
		# 后一个有效 token（方法名）
		var m := i + 1
		while m < tokens.size() and tokens[m].type == TokenType.WHITESPACE:
			m += 1
		if m >= tokens.size():
			continue
		var method_t: Token = tokens[m]
		if method_t.type != TokenType.IDENTIFIER and method_t.type != TokenType.KEYWORD:
			continue
		# 再后一个必须是 "("
		var n := m + 1
		while n < tokens.size() and tokens[n].type == TokenType.WHITESPACE:
			n += 1
		if n >= tokens.size() or tokens[n].value != "(":
			continue
		calls.append({
			"object": _object_name(tokens, k),
			"method": method_t.value,
			"line": prev.line,
			"column": prev.column,
			"args": _extract_args(tokens, n),
		})
	return calls


## 提取源码中所有 `res://` 开头的字符串字面量（去引号，不重复判断交给调用方）。
static func extract_res_paths(p_code: String) -> Array[String]:
	var result: Array[String] = []
	for t in tokenize(p_code):
		if t.type == TokenType.STRING:
			var path := _strip_quote(t.value)
			if path.begins_with("res://"):
				result.append(path)
	return result


## 构建 变量名 → 对象类型 映射（含引用链解析，最多 10 轮收敛）。
## 例: var h = HTTPRequest.new() → {"h": "HTTPRequest"}
static func build_symbol_table(p_code: String) -> Dictionary:
	var tokens := tokenize(p_code)
	var direct: Dictionary = {}
	var refs: Dictionary = {}
	for entry in _collect_assignments(tokens):
		var lhs: String = entry["lhs"]
		var rhs: Array[Token] = entry["rhs"]
		var first: Token = rhs[0]
		if first.type != TokenType.IDENTIFIER and first.type != TokenType.KEYWORD:
			continue
		if first.value in IGNORED_RHS_KEYWORDS:
			continue
		if rhs.size() == 1:
			refs[lhs] = first.value  # 变量引用，稍后解析
		else:
			direct[lhs] = first.value  # HTTPRequest.new() / get_node(...) → 首标识符
	return _resolve_refs(direct, refs)


## 构建 变量名 → 字符串字面量值 映射（含引用链解析）。
## 例: var p = "res://a.gd" → {"p": "res://a.gd"}
static func build_path_var_table(p_code: String) -> Dictionary:
	var tokens := tokenize(p_code)
	var literals: Dictionary = {}
	var refs: Dictionary = {}
	for entry in _collect_assignments(tokens):
		var lhs: String = entry["lhs"]
		var rhs: Array[Token] = entry["rhs"]
		if rhs.size() == 1 and rhs[0].type == TokenType.STRING:
			literals[lhs] = _strip_quote(rhs[0].value)
		elif rhs.size() == 1 and rhs[0].type == TokenType.IDENTIFIER:
			refs[lhs] = rhs[0].value
	return _resolve_refs(literals, refs)


# ============================================================================
# Private Functions
# ============================================================================

# 收集所有"变量赋值"（`x := RHS` / `x = RHS`），返回 {lhs: String, rhs: Array[Token]} 列表。
static func _collect_assignments(p_tokens: Array[Token]) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in p_tokens.size():
		var t: Token = p_tokens[i]
		if t.type != TokenType.OPERATOR or (t.value != ":=" and t.value != "="):
			continue
		# 左侧：前一个有效 token
		var k := i - 1
		while k >= 0 and p_tokens[k].type == TokenType.WHITESPACE:
			k -= 1
		if k < 0:
			continue
		var lhs: Token = p_tokens[k]
		if lhs.type != TokenType.IDENTIFIER and lhs.type != TokenType.KEYWORD:
			continue
		if lhs.value in ["true", "false", "null", "self", "super"]:
			continue
		# 左侧前一个 token：排除属性/参数/索引/枚举赋值
		var k2 := k - 1
		while k2 >= 0 and p_tokens[k2].type == TokenType.WHITESPACE:
			k2 -= 1
		if k2 >= 0:
			var prev: Token = p_tokens[k2]
			if prev.value in NON_ASSIGNMENT_PREV:
				continue
			if prev.type == TokenType.KEYWORD and prev.value in STATEMENT_KEYWORDS:
				continue
		# 右侧：到行尾（行续接已被吞掉，故天然跨行）
		var rhs: Array[Token] = []
		var m := i + 1
		while m < p_tokens.size() and p_tokens[m].type != TokenType.NEWLINE:
			if p_tokens[m].type == TokenType.WHITESPACE:
				m += 1
				continue
			rhs.append(p_tokens[m])
			m += 1
		if rhs.is_empty():
			continue
		out.append({"lhs": lhs.value, "rhs": rhs})
	return out


# 解析引用链：direct 为确定映射，refs 为 变量→变量 引用。
static func _resolve_refs(p_direct: Dictionary, p_refs: Dictionary) -> Dictionary:
	var result := p_direct.duplicate()
	var changed := true
	var iterations := 0
	while changed and iterations < 10:
		changed = false
		iterations += 1
		for key in p_refs:
			if not result.has(key):
				var target: String = p_refs[key]
				if result.has(target):
					result[key] = result[target]
					changed = true
	return result


# 提取调用参数：按括号深度与深度 1 的逗号切分，token 文本以空格连接。
static func _extract_args(p_tokens: Array[Token], p_open_idx: int) -> Array[String]:
	var args: Array[String] = []
	var depth := 1
	var current: Array[String] = []
	var i := p_open_idx + 1
	while i < p_tokens.size():
		var t: Token = p_tokens[i]
		if t.type == TokenType.WHITESPACE or t.type == TokenType.NEWLINE:
			i += 1
			continue
		if t.value == "(":
			depth += 1
			current.append(t.value)
		elif t.value == ")":
			depth -= 1
			if depth == 0:
				if not current.is_empty():
					args.append(" ".join(current))
				break
			current.append(t.value)
		elif t.value == "," and depth == 1:
			args.append(" ".join(current))
			current.clear()
		else:
			current.append(t.value)
		i += 1
	return args


# 生成调用对象名：合并 $/% 前缀，链式调用归一为 ")"。
static func _object_name(p_tokens: Array[Token], p_obj_idx: int) -> String:
	var t: Token = p_tokens[p_obj_idx]
	if t.value == ")":
		return ")"
	if t.value == "]":
		return "]"
	if t.type == TokenType.IDENTIFIER or t.type == TokenType.KEYWORD:
		var k := p_obj_idx - 1
		while k >= 0 and p_tokens[k].type == TokenType.WHITESPACE:
			k -= 1
		if k >= 0 and (p_tokens[k].value == "$" or p_tokens[k].value == "%"):
			return p_tokens[k].value + t.value  # $Node / %Unique
		return t.value
	if t.type == TokenType.STRING:
		return _strip_quote(t.value)
	return ""


# 剥离字符串 token 的前缀（r/R/&/^/@）与引号（含三引号）。
static func _strip_quote(p_value: String) -> String:
	var v := p_value
	if v.length() >= 2 and v[0] in ["r", "R", "&", "^", "@"] and (v[1] == '"' or v[1] == "'"):
		v = v.substr(1)
	if v.begins_with('"""') and v.ends_with('"""') and v.length() >= 6:
		return v.substr(3, v.length() - 6)
	if v.begins_with("'''") and v.ends_with("'''") and v.length() >= 6:
		return v.substr(3, v.length() - 6)
	if v.length() >= 2 and (v[0] == '"' or v[0] == "'"):
		return v.substr(1, v.length() - 2)
	return v


# ============================================================================
# Inner Classes
# ============================================================================

## 单个 Token：保留原始文本（含引号/转义），携带 1-based 行列号。
class Token:
	var type: int = -1
	var value: String = ""
	var line: int = 1
	var column: int = 1


## 单遍字符级扫描状态机。跨行字符串、行续接在推进时同步更新行列号。
class _Engine:
	var _code: String = ""
	var _pos: int = 0
	var _line: int = 1
	var _col: int = 1
	var _tokens: Array[Token] = []


	func _init(p_code: String) -> void:
		_code = p_code


	func _run() -> Array[Token]:
		var len := _code.length()
		while _pos < len:
			var ch: String = _code[_pos]
			
			if ch == "\n":
				var l1 := _line
				var c1 := _col
				_advance_to(_pos + 1)
				_emit(TokenType.NEWLINE, "\n", l1, c1)
			
			elif ch == " " or ch == "\t" or ch == "\r":
				var l2 := _line
				var c2 := _col
				var p2 := _pos
				while _pos < len and (_code[_pos] == " " or _code[_pos] == "\t" or _code[_pos] == "\r"):
					_advance_to(_pos + 1)
				_emit(TokenType.WHITESPACE, _code.substr(p2, _pos - p2), l2, c2)
			
			elif ch == "#":
				var l3 := _line
				var c3 := _col
				var p3 := _pos
				while _pos < len and _code[_pos] != "\n":
					_advance_to(_pos + 1)
				_emit(TokenType.COMMENT, _code.substr(p3, _pos - p3), l3, c3)
			
			elif ch == '"' or ch == "'":
				if _pos + 2 < len and _code.substr(_pos, 3) == ch.repeat(3):
					_parse_quoted(ch.repeat(3), true, "")
				else:
					_parse_quoted(ch, false, "")
			
			elif (ch == "r" or ch == "R") and _pos + 1 < len and _code[_pos + 1] == '"':
				_parse_quoted('"', false, ch)  # raw 字符串
			
			elif ch == "&" and _pos + 1 < len and (_code[_pos + 1] == '"' or _code[_pos + 1] == "'"):
				_parse_quoted(_code[_pos + 1], false, "&")  # StringName
			
			elif ch == "^" and _pos + 1 < len and (_code[_pos + 1] == '"' or _code[_pos + 1] == "'"):
				_parse_quoted(_code[_pos + 1], false, "^")  # NodePath
			
			elif ch == "@" and _pos + 1 < len and (_code[_pos + 1] == '"' or _code[_pos + 1] == "'"):
				_parse_quoted(_code[_pos + 1], false, "@")  # StringName 简写
			
			elif ch == "@":
				var l4 := _line
				var c4 := _col
				var p4 := _pos
				_advance_to(_pos + 1)
				while _pos < len and _is_ident_char(_code[_pos]):
					_advance_to(_pos + 1)
				_emit(TokenType.IDENTIFIER, _code.substr(p4, _pos - p4), l4, c4)
			
			elif ch == "." and _pos + 1 < len and _is_digit(_code[_pos + 1]):
				_parse_number()  # .5
			
			elif _is_digit(ch):
				_parse_number()
			
			elif ch == "\\":
				# 行续接：\ + 行尾空白 + 换行 → 整体吞掉（不产生 token）
				var j := _pos + 1
				while j < len and (_code[j] == " " or _code[j] == "\t" or _code[j] == "\r"):
					j += 1
				if j < len and _code[j] == "\n":
					_advance_to(j + 1)
				else:
					var l5 := _line
					var c5 := _col
					_advance_to(_pos + 1)
					_emit(TokenType.UNKNOWN, "\\", l5, c5)
			
			elif _pos + 1 < len and _code.substr(_pos, 2) in TWO_CHAR_OPS:
				_emit_operator(_code.substr(_pos, 2), 2)
			
			elif ch in SINGLE_OPS:
				_emit_operator(ch, 1)
			
			elif _is_ident_start(ch):
				var l6 := _line
				var c6 := _col
				var p6 := _pos
				while _pos < len and _is_ident_char(_code[_pos]):
					_advance_to(_pos + 1)
				var word := _code.substr(p6, _pos - p6)
				var ttype := TokenType.KEYWORD if word in KEYWORDS else TokenType.IDENTIFIER
				_emit(ttype, word, l6, c6)
			
			else:
				var l7 := _line
				var c7 := _col
				_advance_to(_pos + 1)
				_emit(TokenType.UNKNOWN, ch, l7, c7)
		
		return _tokens


	# 解析普通/三引号/带前缀字符串。p_prefix 为 r/R/&/^/@（可为空）。
	func _parse_quoted(p_quote: String, p_is_triple: bool, p_prefix: String) -> void:
		var sl := _line
		var sc := _col
		var value := p_prefix + p_quote
		_advance_to(_pos + p_prefix.length() + p_quote.length())
		var quote_len := p_quote.length()
		
		while _pos < _code.length():
			var ch := _code[_pos]
			if ch == "\\":
				# 跳过转义（含字符串内行续接），原样保留
				value += ch
				_advance_to(_pos + 1)
				if _pos < _code.length():
					value += _code[_pos]
					_advance_to(_pos + 1)
				continue
			if p_is_triple:
				if _code.substr(_pos, quote_len) == p_quote:
					value += p_quote
					_advance_to(_pos + quote_len)
					_emit(TokenType.STRING, value, sl, sc)
					return
			else:
				if ch == p_quote:
					value += ch
					_advance_to(_pos + 1)
					_emit(TokenType.STRING, value, sl, sc)
					return
			value += ch
			_advance_to(_pos + 1)
		
		# 未闭合（跨行到文件尾）——宽容收尾，不报错
		_emit(TokenType.STRING, value, sl, sc)


	# 解析数字（0x/0b/0o 前缀、_ 分隔、小数点、e 指数，含容错回退）。
	func _parse_number() -> void:
		var start := _pos
		var sl := _line
		var sc := _col
		var i := _pos
		var len := _code.length()
		
		# 前缀进制
		if _code[i] == "0" and i + 1 < len and (_code[i + 1] == "x" or _code[i + 1] == "X" \
				or _code[i + 1] == "b" or _code[i + 1] == "B" or _code[i + 1] == "o" or _code[i + 1] == "O"):
			i += 2
			var digit_start := i
			while i < len and (_is_hex_digit(_code[i]) or _code[i] == "_"):
				i += 1
			if i == digit_start:
				i = start + 1  # 无数字（如 0x）→ 回退仅消费 "0"
			_advance_to(i)
			_emit(TokenType.NUMBER, _code.substr(start, i - start), sl, sc)
			return
		
		# 普通十进制
		var has_dot := false
		var has_exp := false
		while i < len:
			var c := _code[i]
			if _is_digit(c) or c == "_":
				i += 1
			elif c == "." and not has_dot and not has_exp:
				if i + 1 < len and _is_digit(_code[i + 1]):
					has_dot = true
					i += 1
				else:
					break  # 范围 .. 或成员访问
			elif (c == "e" or c == "E") and not has_exp:
				has_exp = true
				i += 1
				if i < len and (_code[i] == "+" or _code[i] == "-"):
					i += 1
			elif (c == "+" or c == "-") and has_exp:
				i += 1
			else:
				break
		
		# 容错：1e / 1e+ 后无数字 → 回退到 e 之前
		var tail := _code.substr(start, i - start)
		while i > start and (tail.ends_with("e") or tail.ends_with("E") \
				or tail.ends_with("+") or tail.ends_with("-") or tail.ends_with("_")):
			i -= 1
			tail = _code.substr(start, i - start)
		
		_advance_to(i)
		_emit(TokenType.NUMBER, _code.substr(start, i - start), sl, sc)


	# 推进扫描位置并同步维护行列号（跨行字符串/续行依赖此逻辑）。
	func _advance_to(p_target: int) -> void:
		while _pos < p_target and _pos < _code.length():
			if _code[_pos] == "\n":
				_line += 1
				_col = 1
			else:
				_col += 1
			_pos += 1


	func _emit_operator(p_op: String, p_len: int) -> void:
		var l := _line
		var c := _col
		_advance_to(_pos + p_len)
		_emit(TokenType.OPERATOR, p_op, l, c)


	func _emit(p_type: int, p_value: String, p_line: int, p_col: int) -> void:
		var t := Token.new()
		t.type = p_type
		t.value = p_value
		t.line = p_line
		t.column = p_col
		_tokens.append(t)


	static func _is_digit(p_ch: String) -> bool:
		return p_ch >= "0" and p_ch <= "9"


	static func _is_hex_digit(p_ch: String) -> bool:
		return _is_digit(p_ch) or (p_ch >= "a" and p_ch <= "f") or (p_ch >= "A" and p_ch <= "F")


	static func _is_ident_start(p_ch: String) -> bool:
		if p_ch == "_":
			return true
		if p_ch >= "a" and p_ch <= "z":
			return true
		if p_ch >= "A" and p_ch <= "Z":
			return true
		return p_ch.unicode_at(0) > 127  # 中文等 Unicode 标识符


	static func _is_ident_char(p_ch: String) -> bool:
		return _is_ident_start(p_ch) or _is_digit(p_ch)
