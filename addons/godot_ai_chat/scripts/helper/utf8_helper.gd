class_name Utf8Helper
extends RefCounted

## UTF-8 辅助工具
##
## 处理逐块到达的字节缓冲区中不完整 UTF-8 序列的检测。


# --- Public Functions ---

## 返回缓冲区末尾不完整 UTF-8 序列的字节数（0 = 末尾字符已完整）
## [param p_buf]: 字节缓冲区
## [return]: 末尾不完整字节序列长度；0 表示缓冲区末尾是一个完整字符
static func incomplete_tail_bytes(p_buf: PackedByteArray) -> int:
	var size: int = p_buf.size()
	if size == 0:
		return 0
	var i: int = size - 1
	while i >= 0 and (p_buf[i] & 0xC0) == 0x80:
		i -= 1
	if i < 0:
		return mini(size, 3)  # 全为 continuation，保守保留最多 3 字节
	var lead: int = p_buf[i]
	var expected: int = 1
	if (lead & 0xE0) == 0xC0:
		expected = 2
	elif (lead & 0xF0) == 0xE0:
		expected = 3
	elif (lead & 0xF8) == 0xF0:
		expected = 4
	var total: int = size - i
	return total if total < expected else 0
