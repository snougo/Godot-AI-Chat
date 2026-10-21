@tool
class_name MarkdownSegment
extends RefCounted
## Markdown 行内解析结果中的一段。
##
## 只有两种形态，用 [member kind] 区分：
## [code]PLAIN[/code] 的 [member text] 是可直接写入 RichTextLabel 的 BBCode 片段
## （可能只是一个标签，也可能是一段纯文本）；
## [code]CODE[/code] 的 [member text] 是行内代码原文，渲染时必须按纯文本处理。


# --- Enums ---

## 片段形态
enum Kind {
	PLAIN, ## BBCode 片段（标签或文本）
	CODE,  ## 行内代码原文
}


# --- Public Vars ---

## 片段形态
var kind: Kind
## 片段内容
var text: String


# --- Built-in Functions ---

func _init(p_kind: Kind, p_text: String) -> void:
	kind = p_kind
	text = p_text
