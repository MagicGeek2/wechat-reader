---
name: wechat-reader
description: 读取公开微信公众号文章的正文、元数据和图片型正文，并识别验证码与访问边界；用户给出 mp.weixin.qq.com 链接或请求读取公开文章时使用。
---

# 微信公众号文章读取

## 适用范围

处理公开的 `mp.weixin.qq.com/s/...` 文章链接。单篇链接读取和“给定公众号后从其文章列表定位文章”是两个不同任务：后者必须先找到公众号来源页或文章列表，不能只用标题做全网搜索来冒充账号内检索。

默认使用 Chrome 或 Safari 访问路径，不使用 Firefox，除非用户明确要求复用 Firefox 登录态。不要调用用户的微信登录态；如页面要求人工验证，说明原因并停在验证边界。

## 标准读取路径

1. 对链接去重，低并发或顺序执行；已有结果优先使用缓存。用脚本读取一篇或多篇文章：

   ```bash
   python3 scripts/read_wechat.py "https://mp.weixin.qq.com/s/..."
   ```

2. 脚本从服务端 HTML 读取 `#activity-name`、`#js_name`、`#js_content`，并以 `og:title`、描述字段和图片 shell 作为后备。输出 JSON Lines；不要把 HTTP 200 单独当作正文成功。

3. 按状态处理：

   - `ok`：使用 `content`，同时报告标题、作者、图片数量和来源链接。
   - `image_only`：正文节点为空但已提取 `image_urls`。按原顺序打开或 OCR 所有图片，再合并为可读正文；图片文章不能直接报告为“无法读取”。macOS 可编译 `scripts/vision_ocr.swift`，从 JSON 或逐行 HTTPS 图片 URL 输入并输出 JSONL；没有 Vision 运行时则改用可用的视觉读取工具。
   - `metadata_only`：只有元数据，明确说明正文未取得。
   - `captcha_required`：最终地址含 `/mp/wappoc_appmsgcaptcha` 或页面出现“环境异常/完成验证后即可继续访问”。停止自动读取，不尝试破解、打码、代理池或轮换 IP。

4. 验证码只允许低频退避后有限重试；仍被拦截时，可在用户授权的 Chrome/Safari 会话中让用户人工完成验证，再从同一会话读取。不能把镜像、搜索摘要或第三方整理版称为微信原文。

## 稳定性与汇报

- 请求之间加入数秒级随机间隔，避免并发扫同一出口；记录输入 URL、最终 URL、状态、正文字符数、图片数、标题和作者。
- 报告时区分：正文已读、图片已提取但尚未 OCR、验证码拦截、网络错误和来源镜像。
- 文章正文通常是服务端渲染的，不要因为没有 JavaScript 执行环境就放弃；若 `#js_content` 缺失，转入图片读取路径。
