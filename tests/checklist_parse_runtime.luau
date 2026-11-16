local parser = require("../checklist_parse")

local function expect(text, titles)
	local items = parser.parse(text)
	assert(#items == #titles, `expected {#titles} items, got {#items}`)
	for i, title in titles do
		assert(items[i].title == title, `item {i}: expected {title}, got {items[i].title}`)
	end
	return items
end

-- Keep all six issues, even when an unrelated list has more entries.
local issues = expect([==[发现六个问题：

1. **读取状态竞态** — 并发读取会返回旧值。
重试时同样会触发。
   - 先写复现测试。
   - 再隔离状态。
   ```text
   8. 这行是代码中的内容。
   ```
2. 写入重入
3. 未释放句柄
4. 错误事件缺失
5. 版本约束
6. 提示不一致

以上是这次审查发现的问题。

- 建议一
- 建议二
- 建议三
- 建议四
- 建议五
- 建议六
- 建议七
]==], {
	"读取状态竞态", "写入重入", "未释放句柄", "错误事件缺失", "版本约束", "提示不一致",
})
assert(issues[1].body:find("重试时同样会触发。", 1, true), "retain natural multiline continuation")
assert(issues[1].body:find("   - 再隔离状态。", 1, true), "nested steps stay with their parent issue")
assert(issues[1].body:find("   8. 这行是代码中的内容。", 1, true), "retain the item's code block")
assert(issues[6].body == "提示不一致", "exclude paragraphs after the list")

expect([==[````markdown
1. 外部代码示例
```
2. 仍在外部代码里
````

- [ ] 保留多行内容
- [x] 核对输出
  - 细分步骤
]==], { "保留多行内容", "核对输出" })

local headings = expect([==[## 问题
### **Bug #1: 缓存过期**
缓存未及时更新。
#### 复现
- 步骤一
- 步骤二
### 问题 2：键冲突
有两个请求使用了同一个键。
## 总结
这个段落不用导入。
]==], { "缓存过期", "键冲突" })
assert(headings[1].body:find("- 步骤二", 1, true), "heading details stay attached")
assert(not headings[2].body:find("这个段落不用导入。", 1, true), "sibling sections stay separate")

expect("一、问题甲\r\n二、问题乙", { "问题甲", "问题乙" })
expect("**1. 第一条**\n详述。\n**2. 第二条**", { "第一条", "第二条" })
expect("这段普通文字不是清单。", {})
expect("", {})
expect("- 只有一条", {})
expect("~~~text\n1. 代码示例\n2. 代码示例\n~~~", {})
expect("    1. 缩进代码示例\n    2. 缩进代码示例", {})

local long = string.rep("蛛", 95)
local unicode = expect("1. " .. long .. "\n2. 下一条 🕸", { string.rep("蛛", 88) .. "…", "下一条 🕸" })
assert(unicode[1].body == long, "title truncation never truncates the original text")
