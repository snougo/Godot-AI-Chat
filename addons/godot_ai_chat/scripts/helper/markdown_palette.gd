@tool
class_name MarkdownPalette
extends RefCounted

## Markdown 渲染配色与尺寸。
##
## 所有渲染用色集中在这里，渲染层不再持有任何色值常量。
## [method from_base] 可按"背景色 + 正文色"派生结构色（表格/引用），用于适配浅色主题；
## 语义色（标题、粗体、斜体、链接、行内代码）是固定色板，不参与派生：
## 它们与背景色没有确定关系，强行派生会在浅色主题下失去辨识度。


# --- Public Vars ---

## 正文文字色（供派生计算与外部取色，渲染层不直接使用）
var text: Color = Color("#dce1e8")

## 标题文字色
var heading: Color = Color("#ff729c")
## 粗体文字色
var bold: Color = Color("#94bcff")
## 斜体文字色
var italic: Color = Color("#569CD6")
## 粗斜体文字色
var bold_italic: Color = Color("#c792ea")
## 链接文字色
var link: Color = Color("#B39DDB")
## 行内代码文字色
var inline_code: Color = Color("#d2cf95")

## 表格边框
var table_border: Color = Color(0.36, 0.42, 0.5)
## 表格表头底色
var table_header_bg: Color = Color("#2d2d5e")
## 表格数据行隔行底色
var table_row_alt_bg: Color = Color(0.22, 0.26, 0.31)
## 引用块左侧竖条
var quote_bar: Color = Color("#569CD6")
## 引用块底色
var quote_bg: Color = Color(0.22, 0.26, 0.31)

## 单元格左右内边距
var cell_pad_h: int = 8
## 单元格上下内边距
var cell_pad_v: int = 4
## 引用块内容内边距
var quote_pad: int = 8

## 无序列表各层级符号（层级超出时复用最后一档）
var list_bullets: Array[String] = ["•", "◦", "▪"]


# --- Public Functions ---

## 按背景色与正文色派生一份配色（结构色随背景走，语义色沿用默认色板）。
## [param p_bg]: 消息背景色，例如 StyleBoxFlat.bg_color
## [param p_text]: 正文文字色
## [注意] 派生的表头底色会从紫色变成中性灰 —— 想保留紫色就不要用本方法。
static func from_base(p_bg: Color, p_text: Color) -> MarkdownPalette:
	var palette: MarkdownPalette = MarkdownPalette.new()
	palette.text = p_text
	palette.table_border = p_bg.lerp(p_text, 0.28)
	palette.table_header_bg = p_bg.lerp(p_text, 0.1)
	palette.table_row_alt_bg = p_bg.lerp(p_text, 0.07)
	palette.quote_bg = palette.table_row_alt_bg
	return palette
