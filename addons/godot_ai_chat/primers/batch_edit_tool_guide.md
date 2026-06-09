# batch_edit 工具使用说明

## 适用场景
当需要同时对脚本进行多处编辑时使用，避免多次调用导致行号偏移。

## 操作类型

| 类型 | 参数 | 说明 |
|------|------|------|
| `insert` | `target_line`, `content` | 在 target_line 之后插入 content |
| `delete` | `start_line`, `end_line` | 删除 start_line 到 end_line（含两端） |
| `replace` | `start_line`, `end_line`, `content` | 将 start_line 到 end_line 替换为 content |

## 核心规则

1. **所有行号均基于修改前的原始文件**，操作之间互不影响
2. 同一位置多个 insert 允许，按数组顺序依次插入
3. **操作范围重叠会直接报错**，不允许执行
4. content 中含 `\\n` 会自动展开为多行

## 示例

同时完成函数重命名 + 添加新函数：

```
"operations": [
    {"type": "replace", "start_line": 15, "end_line": 22, "content": "func new_name():\\n    return 42"},
    {"type": "insert",  "target_line": 30, "content": "func helper():\\n    pass"}
]
```

## 注意

- 每次只提交当前脚本的编辑操作
- 执行后会返回完整的带行号脚本内容
