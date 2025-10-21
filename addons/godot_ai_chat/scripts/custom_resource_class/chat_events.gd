extends Resource
class_name ChatEventsResource

# 用户交互事件
signal user_message_submitted(user_prompt: String)
signal stop_generation_requested
signal new_chat_requested
signal settings_saved_and_reconnect_requested
signal reconnect_requested
signal model_selection_changed(model_name: String)
signal chat_archive_save_requested(file_path: String, save_mode: ChatUI.ChatMessagesSaveMode)
signal chat_archive_load_requested(archive_name: String)

# 网络与API流程事件
signal connection_check_started(user_prompt: String)
signal connection_check_succeeded(user_prompt: String)
signal connection_check_failed(error_message: String)

signal model_list_fetch_started
signal model_list_updated(model_list: Array)
signal model_list_fetch_failed(error_message: String)

signal ai_chat_request_started(context: Array)
signal ai_response_chunk_received(chunk: String)
signal ai_response_stream_completed(final_message: Dictionary)
signal ai_response_stream_canceled
signal ai_chat_request_failed(error_message: String)

# 数据与状态更新事件
signal chat_cleared
signal user_message_appended(message: Dictionary)
signal assistant_message_block_created
signal assistant_message_updated(final_message: Dictionary)
signal tool_message_appended(message: Dictionary)
signal token_usage_updated(prompt: int, completion: int, total: int)

# 工具工作流事件
signal tool_workflow_started
signal tool_workflow_step_completed(tool_message: Dictionary)
signal tool_workflow_succeeded(final_message: Dictionary)
signal tool_workflow_failed(error_message: String)

# UI状态控制事件
signal update_ui_state(state: ChatUI.UIState, payload: String)
