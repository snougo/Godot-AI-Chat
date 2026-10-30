@tool
extends Control

## 聊天中心控制器
##
## 插件的主入口，作为组合根负责依赖注入，并协调聊天循环。
## 会话管理逻辑已抽取至 AIChatController。

# --- Constants ---

const AIChatCurrentChatWindow = preload("res://addons/godot_ai_chat/scripts/ui/current_chat_window.gd")
const AIChatNetworkManager = preload("res://addons/godot_ai_chat/scripts/network/network_manager.gd")
const AIChatAgentOrchestrator = preload("res://addons/godot_ai_chat/scripts/core/agent_orchestrator.gd")
const AttachmentProcessor := preload("res://addons/godot_ai_chat/scripts/helper/attachment_processor.gd")
const ContextCompressor := preload("res://addons/godot_ai_chat/scripts/core/context_compressor.gd")
const AIChatController = preload("res://addons/godot_ai_chat/scripts/core/chat_controller.gd")
const AIChatUI = preload("res://addons/godot_ai_chat/scripts/ui/chat_ui.gd")


# --- @onready Vars ---

@onready var _chat_ui: AIChatUI = $ChatUI
@onready var _network_manager: AIChatNetworkManager = $NetworkManager
@onready var _current_chat_window: AIChatCurrentChatWindow = $CurrentChatWindow
@onready var _agent_orchestrator: AIChatAgentOrchestrator = $AgentOrchestrator


# --- Private Vars ---

var _chat_controller: AIChatController
var _is_performing_cleanup: bool = false
var _is_plugin_init: bool = false
var _compression_config: ContextCompressionConfig = null


# --- Built-in Functions ---

func _ready() -> void:
	ToolRegistry.load_default_tools()
	
	var session_manager: AIChatSessionManager = AIChatSessionManager.new()
	_chat_controller = AIChatController.new()
	_chat_controller.setup(session_manager, _chat_ui, _current_chat_window)
	
	_agent_orchestrator.network_manager = _network_manager
	_agent_orchestrator.current_chat_window = _current_chat_window
	_agent_orchestrator.chat_ui = _chat_ui
	
	_current_chat_window.chat_list_container = _chat_ui.get_chat_list_container()
	_current_chat_window.chat_scroll_container = _chat_ui.get_chat_scroll_container()
	
	await get_tree().process_frame
	_bind_ui_signals()


# --- Public Functions ---

func get_chat_ui() -> AIChatUI:
	return _chat_ui


# --- Private Functions ---

func _bind_ui_signals() -> void:
	_chat_ui.mouse_entered.connect(_on_chat_ui_mouse_entered)
	
	_chat_ui.new_chat_button_pressed.connect(_on_new_chat_requested)
	_chat_ui.compress_button_pressed.connect(_on_compress_requested)
	_chat_ui.load_chat_button_pressed.connect(_on_load_chat_requested)
	_chat_ui.delete_chat_button_pressed.connect(_on_delete_chat_requested)
	_chat_ui.save_as_markdown_button_pressed.connect(_on_export_markdown_requested)
	
	_chat_ui.send_button_pressed.connect(_on_user_send_message)
	_chat_ui.stop_button_pressed.connect(_on_stop_requested)
	
	_chat_ui.workspace_changed.connect(_on_workspace_changed)
	
	_chat_ui.reconnect_button_pressed.connect(_network_manager.get_model_list)
	_chat_ui.settings_save_button_pressed.connect(_on_settings_save_requested)
	_chat_ui.model_selection_changed.connect(_on_model_selection_changed)
	
	_network_manager.get_model_list_request_started.connect(_chat_ui.update_ui_state.bind(AIChatUI.UIState.CONNECTING))
	_network_manager.get_model_list_request_succeeded.connect(_chat_ui.update_model_list)
	_network_manager.get_model_list_request_failed.connect(_chat_ui.get_model_list_request_failed)
	
	_network_manager.new_chat_request_sending.connect(_on_new_chat_request_sending)
	_current_chat_window.token_usage_updated.connect(_chat_ui.update_token_usage_display)


func _run_chat_loop() -> void:
	_chat_ui.update_ui_state(AIChatUI.UIState.WAITING_RESPONSE)
	
	# 每次聊天循环开始前仅重载核心工具（不重扫技能），确保修改 main_agent_tool_config.tres 后立即生效
	ToolRegistry.reload_core_tools_only()
	
	if not _network_manager.new_stream_chunk_received.is_connected(_on_stream_chunk):
		_network_manager.new_stream_chunk_received.connect(_on_stream_chunk)
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	
	await _agent_orchestrator.run_chat_cycle(_current_chat_window.chat_history, settings)
	
	if _network_manager.new_stream_chunk_received.is_connected(_on_stream_chunk):
		_network_manager.new_stream_chunk_received.disconnect(_on_stream_chunk)
	
	if _agent_orchestrator.is_cancelled:
		_chat_ui.update_ui_state(AIChatUI.UIState.IDLE, "Stopped")
		_rollback_incomplete_turn()
	else:
		_chat_ui.update_ui_state(AIChatUI.UIState.IDLE)
	
	# 回合结束：把累计用量落库。
	# 中间各轮已在「每轮请求发起前」落库，此处补齐最后一个请求的用量，
	# 避免用户不发起下一轮就直接切换会话时丢掉末轮消耗。
	_sync_token_usage_to_history()
	
	if _current_chat_window.chat_history:
		_current_chat_window.chat_history.emit_changed()


# 停止生成后的清理：先丢弃未落库的流式消息，再由数据层回滚未闭环的轮次
# 视图刷新由 ChatMessageHistory.turn_rolled_back 信号驱动
func _rollback_incomplete_turn() -> void:
	_current_chat_window.discard_streaming_message()
	
	var history: ChatMessageHistory = _current_chat_window.chat_history
	if history != null:
		history.rollback_incomplete_turn()


# 把当前累计用量覆盖式同步到会话存档
# 覆盖语义天然幂等：多次调用不会重复累加，因此可以放心地在
# 「每轮请求发起前」与「整个回合结束后」两个时机都调用，互为兜底。
func _sync_token_usage_to_history() -> void:
	var history: ChatMessageHistory = _current_chat_window.chat_history
	if history == null:
		return
	history.set_token_usage(_chat_ui.get_token_usage_snapshot())


func _get_compression_config() -> ContextCompressionConfig:
	if _compression_config:
		return _compression_config
	
	if ResourceLoader.exists(PluginPaths.COMPRESSION_CONFIG_PATH):
		_compression_config = load(PluginPaths.COMPRESSION_CONFIG_PATH) as ContextCompressionConfig
		return _compression_config
	
	# 文件不存在：生成一份全默认配置作为模板（默认字段为空，校验会失败并弹窗提示）
	_compression_config = ContextCompressionConfig.new()
	ResourceSaver.save(_compression_config, PluginPaths.COMPRESSION_CONFIG_PATH)
	ToolBox.update_editor_filesystem(PluginPaths.COMPRESSION_CONFIG_PATH)
	return _compression_config


func _try_compress_context() -> Dictionary:
	var history: ChatMessageHistory = _current_chat_window.chat_history
	var config: ContextCompressionConfig = _get_compression_config()
	
	# 配置完整性/格式校验：不通过即判定失败，不发起任何请求
	var config_error: String = _validate_compression_config(config)
	if not config_error.is_empty():
		_compression_config = null
		return {"success": false, "error": config_error, "error_kind": "config"}
	
	_chat_ui.update_ui_state(AIChatUI.UIState.COMPRESSING)
	
	var compressor: ContextCompressor = ContextCompressor.new()
	var result: Dictionary = await compressor.compress_context(history, _network_manager, config)
	
	if not result.success:
		AIChatLogger.error("[AIChatHub] Context compression failed: " + String(result.error))
		# 失败后丢弃缓存：用户修正 .tres 后下一次即可生效，无需重开面板
		_compression_config = null
		_chat_ui.update_ui_state(AIChatUI.UIState.IDLE)
		return {
			"success": false,
			"error": String(result.get("error", "Unknown")),
			"error_kind": String(result.get("error_kind", "runtime"))
		}
	
	var ok: bool = _chat_controller.create_session_from_history(result.new_history)
	
	if ok:
		AIChatLogger.info("[AIChatHub] Context compressed. New session loaded.")
		return {"success": true}
	
	_chat_ui.update_ui_state(AIChatUI.UIState.IDLE)
	return {"success": false, "error": "Failed to save compressed session.", "error_kind": "other"}


func _validate_compression_config(p_config: ContextCompressionConfig) -> String:
	if p_config == null:
		return "Compression config is missing or failed to load. Check that the file exists and is valid."
	return p_config.validate()


# 构造压缩失败的弹窗文案
# [param p_error]: 错误详情
# [param p_kind]: 错误类型（config / runtime / other）
# [param p_blocked_send]: 是否为「用户消息被拦截」场景
func _build_compression_failure_message(p_error: String, p_kind: String, p_blocked_send: bool = false) -> String:
	var msg: String = "Context compression failed."
	if p_blocked_send:
		msg += " Your message was NOT sent."
	msg += "\n\n" + p_error + "\n\n"
	
	match p_kind:
		"config":
			msg += "Config file:\n" + PluginPaths.COMPRESSION_CONFIG_PATH + "\n\n"
			msg += "Fix the listed fields, or set `enabled` to false to fall back to simple truncation."
		"runtime":
			msg += "The summarization request failed (network error, timeout, or server error).\n"
			msg += "Check that the endpoint is reachable, then try again."
		_:
			msg += "Check the compression configuration and try again.\n\n"
			msg += "Config file:\n" + PluginPaths.COMPRESSION_CONFIG_PATH
	
	return msg


# --- Signal Callbacks ---

func _on_user_send_message(p_text: String) -> void:
	if not _chat_controller.has_active_session() or not _current_chat_window.chat_history:
		_chat_ui.show_confirmation("No chat active. Please click 'New Chat' or 'Load Chat' to start.")
		return
	
	var settings: PluginSettingsConfig = ToolBox.get_plugin_settings()
	
	# 同时确保 Sub-Agent 配置文件存在（与压缩配置同一时机创建）
	SubAgentConfig.get_config()
	
	# 只有轮次达到阈值时才读取压缩配置：
	# 未达标时完全不触碰配置，避免一个损坏的 .tres 把正常对话也卡住
	if _current_chat_window.chat_history.get_turn_count() >= settings.max_chat_turns:
		var compression_config: ContextCompressionConfig = _get_compression_config()
		
		# 文件存在但加载失败（脚本被改/文件损坏）：按配置错误处理，不发送消息
		if compression_config == null:
			_chat_ui.show_confirmation(_build_compression_failure_message(
				"The config file exists but failed to load (script changed or file corrupted).", "config", true))
			return
		
		if compression_config.enabled:
			# 压缩前的配置校验：不完整则弹窗拦截，保留用户输入，不发起请求
			var config_error: String = _validate_compression_config(compression_config)
			if not config_error.is_empty():
				_compression_config = null
				_chat_ui.show_confirmation(_build_compression_failure_message(config_error, "config", true))
				return
			
			var compress_result: Dictionary = await _try_compress_context()
			if not compress_result.success:
				# 压缩失败（配置错误 / 请求失败）一律中止本次发送，输入框内容保留
				_chat_ui.show_confirmation(_build_compression_failure_message(
					String(compress_result.get("error", "Unknown")),
					String(compress_result.get("error_kind", "other")),
					true
				))
				return
			
			# 压缩成功：新会话已加载，输入内容保留在输入框中，由用户决定是否继续发送
			_chat_ui.update_ui_state(AIChatUI.UIState.IDLE, "Context compressed. Ready for new input.")
			return
	
	# 真正发送时才清空输入框
	_chat_ui.clear_user_input()
	var processed: Dictionary = AttachmentProcessor.process_input(p_text)
	_current_chat_window.append_user_message(processed.final_text, processed.images)
	_run_chat_loop()


func _on_stream_chunk(p_chunk: Dictionary) -> void:
	if _chat_ui.current_state != AIChatUI.UIState.RESPONSE_GENERATING:
		_chat_ui.update_ui_state(AIChatUI.UIState.RESPONSE_GENERATING)
	
	# 必须使用发起本轮流式请求的那个 Provider 实例，而非可能已被重建的 current_provider
	var provider: BaseLLMProvider = _network_manager.streaming_provider
	if provider == null:
		return
	
	_current_chat_window.handle_stream_chunk(p_chunk, provider)


# 每轮请求发起前：先结算上一轮（重置当前请求计数），再把累计用量落库
func _on_new_chat_request_sending() -> void:
	# 必须先结算：否则新一轮的用量会被上一轮的「只增不减」夹取挡住
	_chat_ui.prepare_for_new_request()
	_sync_token_usage_to_history()


func _on_stop_requested() -> void:
	if _is_performing_cleanup:
		return
	
	_is_performing_cleanup = true
	_agent_orchestrator.cancel_workflow()
	_is_performing_cleanup = false


func _on_new_chat_requested() -> void:
	_on_stop_requested()
	_chat_controller.create_new_chat()


func _on_compress_requested() -> void:
	_on_stop_requested()
	
	var config: ContextCompressionConfig = _get_compression_config()
	if config != null and not config.enabled:
		_chat_ui.show_confirmation("Context compression is disabled. Enable it in:\n" + PluginPaths.COMPRESSION_CONFIG_PATH)
		return
	
	if not _chat_controller.has_active_session() or not _current_chat_window.chat_history:
		_chat_ui.show_confirmation("No chat active. Please create or load a chat first.")
		return
	
	var compress_result: Dictionary = await _try_compress_context()
	if compress_result.success:
		# 压缩成功：已创建新会话并加载，恢复空闲状态
		_chat_ui.update_ui_state(AIChatUI.UIState.IDLE, "Context compressed. New session loaded.")
		return
	
	_chat_ui.update_ui_state(AIChatUI.UIState.IDLE)
	_chat_ui.show_confirmation(_build_compression_failure_message(
		String(compress_result.get("error", "Unknown")),
		String(compress_result.get("error_kind", "other")),
		false
	))


func _on_load_chat_requested(p_session_name: String) -> void:
	_on_stop_requested()
	_chat_controller.load_chat(p_session_name)


func _on_delete_chat_requested(p_session_name: String) -> void:
	_chat_controller.delete_chat(p_session_name)


func _on_export_markdown_requested(p_path: String) -> void:
	_chat_controller.export_markdown(p_path)


func _on_settings_save_requested() -> void:
	_network_manager.get_model_list()
	_chat_controller.update_turn_info()


func _on_model_selection_changed(p_model_name: String) -> void:
	_network_manager.set_model_name(p_model_name)
	# 同步给视图层，用于助手消息标题展示模型名
	_current_chat_window.current_model_name = p_model_name


func _on_chat_ui_mouse_entered() -> void:
	if _chat_ui.mouse_entered.is_connected(_on_chat_ui_mouse_entered):
		_chat_ui.mouse_entered.disconnect(_on_chat_ui_mouse_entered)
	
	if not _is_plugin_init:
		_is_plugin_init = true
		_chat_controller.load_latest_on_init()
	
	await get_tree().create_timer(0.5).timeout
	_network_manager.get_model_list()


func _on_workspace_changed(p_new_path: String) -> void:
	_chat_controller.handle_workspace_change(p_new_path)
