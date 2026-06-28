@tool
class_name ToolResult
extends RefCounted

## 工具执行结果的统一返回类型
##
## 提供工厂方法统一构造成功/失败/带图片/带元数据的结果，
## 替代旧的 Dictionary + 字符串 key 约定模式。

enum Status { OK, FAIL }

## 元数据（extra，避免与 Object.has_meta/get_meta 重名）
var extra: Dictionary:
	get:
		return _meta

## 旧代码兼容属性：res.attachments.image_data / res.attachments.mime
var attachments: Dictionary:
	get:
		return {
			"image_data": _image_data,
			"mime": _image_mime
		}

var _status: Status
var _data: String
var _image_data: PackedByteArray
var _image_mime: String
var _meta: Dictionary = {}


func _init(p_status: Status, p_data: String, p_image_data: PackedByteArray, p_image_mime: String, p_meta: Dictionary = {}) -> void:
	_status = p_status
	_data = p_data
	_image_data = p_image_data
	_image_mime = p_image_mime
	_meta = p_meta


# --- 工厂方法 ---

static func ok(p_data: String = "", p_meta: Dictionary = {}) -> ToolResult:
	return ToolResult.new(Status.OK, p_data, PackedByteArray(), "", p_meta)

static func fail(p_error: String, p_meta: Dictionary = {}) -> ToolResult:
	return ToolResult.new(Status.FAIL, p_error, PackedByteArray(), "", p_meta)

static func ok_with_image(p_data: String, p_image_data: PackedByteArray, p_mime: String = "image/png", p_meta: Dictionary = {}) -> ToolResult:
	return ToolResult.new(Status.OK, p_data, p_image_data, p_mime, p_meta)


# --- 查询方法 ---

func is_ok() -> bool:
	return _status == Status.OK

func is_fail() -> bool:
	return _status == Status.FAIL

func get_data() -> String:
	return _data

func has_image() -> bool:
	return not _image_data.is_empty()

func get_image_data() -> PackedByteArray:
	return _image_data

func get_image_mime() -> String:
	return _image_mime

func has_extra(p_key: String) -> bool:
	return _meta.has(p_key)

func get_extra(p_key: String, p_default: Variant = null) -> Variant:
	return _meta.get(p_key, p_default)
