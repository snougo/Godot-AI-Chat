@tool
extends AiTool

## Lists available file backups or restores files from a specific backup.
## Acts as the manual rollback mechanism for run_editor_script operations.


# --- Built-in Functions ---

func _init() -> void:
	tool_name = "rollback_files"
	tool_description = "Roolback files if needed."


# --- Public Functions ---

func get_parameters_schema() -> Dictionary:
	return {
		"type": "object",
		"properties": {
			"action": {
				"type": "string",
				"enum": ["list", "rollback"],
				"description": "'list' — show all available backups with BackupIDs. 'rollback' — restore files from a specific backup."
			},
			"backup_id": {
				"type": "string",
				"description": "Required for 'rollback' action."
			}
		},
		"required": ["action"]
	}


func execute(p_args: Dictionary) -> ToolResult:
	var action: String = p_args.get("action", "")
	
	match action:
		"list":
			return _list_backups()
		"rollback":
			var backup_id: String = p_args.get("backup_id", "")
			if backup_id.is_empty():
				return ToolResult.fail("'backup_id' is required for 'rollback' action.")
			return _perform_rollback(backup_id)
		_:
			return ToolResult.fail("'action' must be 'list' or 'rollback'.")


# --- Private Functions ---

# List all available backups in the backup directory.
func _list_backups() -> ToolResult:
	if not DirAccess.dir_exists_absolute(PluginPaths.BACKUP_DIR):
		return ToolResult.ok("**No backups found.** The backup directory does not exist.")
	
	var dir: DirAccess = DirAccess.open(PluginPaths.BACKUP_DIR)
	if not dir:
		return ToolResult.fail("Cannot open backup directory.")
	
	var backups: Array[Dictionary] = []
	
	dir.list_dir_begin()
	var file_name: String = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".tres"):
			var backup_path: String = PluginPaths.BACKUP_DIR + file_name
			var backup: EditorScriptAutoBackup = ResourceLoader.load(backup_path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
			if backup:
				backups.append({
					"id": backup.backup_id,
					"timestamp": backup.timestamp,
					"file_count": backup.file_paths.size(),
					"created": backup.audit_created.size(),
					"modified": backup.audit_modified.size(),
					"deleted": backup.audit_deleted.size()
				})
		file_name = dir.get_next()
	dir.list_dir_end()
	
	if backups.is_empty():
		return ToolResult.ok("**No backups found.** The backup directory is empty.")
	
	# Sort by timestamp descending (newest first)
	backups.sort_custom(func(a, b): return a.timestamp > b.timestamp)
	
	var text: String = "**Available backups:**\n\n"
	for b in backups:
		var time_str: String = Time.get_datetime_string_from_unix_time(b.timestamp, false)
		text += "- BackupID: **`%s`** (from: %s, %d files backed up)\n" % [b.id, time_str, b.file_count]
		text += "- Created: %d  |  Modified: %d  |  Deleted: %d\n" % [b.created, b.modified, b.deleted]
	
	text += "\nTo restore a backup, use `action=\"rollback\"` and the `backup_id` from above."
	return ToolResult.ok(text)


# Perform rollback: restore all files from a given backup.
func _perform_rollback(p_backup_id: String) -> ToolResult:
	var backup_path: String = PluginPaths.BACKUP_DIR + p_backup_id + ".tres"
	
	if not ResourceLoader.exists(backup_path):
		return ToolResult.fail("**Backup not found:** `%s`\n\nUse `action=\"list\"` to see available backups." % p_backup_id)
	
	var backup: EditorScriptAutoBackup = ResourceLoader.load(backup_path, "", ResourceLoader.CacheMode.CACHE_MODE_IGNORE)
	if not backup:
		return ToolResult.fail("Failed to load backup `%s`." % p_backup_id)
	
	var files_map: Dictionary = backup.get_files_map()
	var errors: Array[String] = []
	var restored_count: int = 0
	var deleted_count: int = 0
	var skipped_count: int = 0
	
	# 1. Delete created files
	for path in backup.audit_created:
		if not FileAccess.file_exists(path):
			skipped_count += 1
			continue
		var err: Error = DirAccess.remove_absolute(path)
		if err == OK:
			deleted_count += 1
		else:
			errors.append("Delete created file failed: %s (%s)" % [path, error_string(err)])
	
	# 2. Restore modified files
	for path in backup.audit_modified:
		if not files_map.has(path):
			skipped_count += 1
			continue
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if not file:
			errors.append("Cannot open modified file for write: %s" % path)
			continue
		file.store_buffer(files_map[path])
		file.close()
		restored_count += 1
	
	# 3. Restore deleted files
	for path in backup.audit_deleted:
		if not files_map.has(path):
			skipped_count += 1
			continue
		
		# Ensure parent directory exists
		var parent_dir: String = path.get_base_dir()
		var dir: DirAccess = DirAccess.open(parent_dir)
		if not dir:
			dir = DirAccess.open("res://")
			if dir:
				var rel_parent: String = parent_dir.trim_prefix("res://")
				if rel_parent.begins_with("/"):
					rel_parent = rel_parent.substr(1)
				if not rel_parent.is_empty():
					dir.make_dir_recursive(rel_parent)
		
		var file: FileAccess = FileAccess.open(path, FileAccess.WRITE)
		if not file:
			errors.append("Cannot open deleted file for write: %s" % path)
			continue
		file.store_buffer(files_map[path])
		file.close()
		restored_count += 1
	
	# Only remove backup on fully successful rollback
	if errors.is_empty():
		DirAccess.remove_absolute(backup_path)
	
	# Build result
	var result: String = "**Rollback completed for `%s`.**\n\n" % p_backup_id
	if deleted_count > 0:
		result += "- Deleted %d created file(s)\n" % deleted_count
	if restored_count > 0:
		result += "- Restored %d file(s)\n" % restored_count
	if skipped_count > 0:
		result += "- %d file(s) skipped (no backup content or already missing)\n" % skipped_count
	if not errors.is_empty():
		result += "\n**%d error(s):**\n" % errors.size()
		for e in errors:
			result += "- %s\n" % e
	
	if errors.is_empty():
		result += "\nBackup file has been removed."
	else:
		result += "\n**Backup preserved for manual recovery:** `%s`" % backup_path
	
	ToolBox.refresh_editor_filesystem()
	
	return ToolResult.ok(result)
