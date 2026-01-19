---
name: auto-skill-generator
description: 根据用户需求自动创建自定义 SKILL.md 文档
category: GodotAIChatPlugin
---

# 自动技能生成器 (Auto Skill Generator)

## 概览 (Overview)
本技能根据用户的需求和规范，自动生成格式正确的 Claude Code Skills 所需的 SKILL.md 文档。

## 触发条件 (Activation)
当用户请求创建新技能、提及“create skill”（创建技能）、“generate SKILL.md”（生成 SKILL.md），或描述了一个可以转化为 Skill 技能的具体自动化需求时。

## 指令 (Instructions)
1. **分析用户需求**，以理解期望的技能功能。
2. **确定合适的类别**（Dev、Docs、Testing、Security、DevOps、Data）。
3. **生成一个短横线命名（kebab-case）的技能名称**，需清晰代表该功能。
4. **编写一段简明的描述**（一句话），解释该技能何时激活。
5. **创建 SKILL.md 结构**，包含：
   - 包含 name（名称）、description（描述）和 category（类别）的正确 Frontmatter。
   - 清晰的概览部分。
   - 具体的触发条件。
   - 详细的逐步指令。
   - 展示输入/输出的具体示例。
6. **确保该技能具有可执行性**，并为LLM模型提供清晰的指导。
7. **验证格式**是否符合标准的 SKILL.md 模板。

## 示例 (Examples)

**输入：** “创建一个根据代码注释自动生成 API 文档的技能”
**输出：** 一个完整的 SKILL.md，名称为 “api-doc-generator”，类别为 “Docs”，并包含解析注释和生成文档的详细指令。

**输入：** “我需要一个用于为 Python 项目设置 Docker 容器的技能”
**输出：** 一个完整的 SKILL.md，名称为 “python-docker-setup”，类别为 “DevOps”，并包含逐步的容器配置指令。

**输入：** “制作一个为 JavaScript 函数创建单元测试的技能”
**输出：** 一个完整的 SKILL.md，名称为 “js-unit-test-generator”，类别为 “Testing”，并包含详细的测试生成步骤。
