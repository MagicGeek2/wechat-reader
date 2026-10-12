# 图片型文章 OCR

当 `read_wechat.py` 返回 `image_only` 时，先保留 `image_urls` 的原始顺序，再把 URL 列表交给 `scripts/vision_ocr.swift`。该辅助脚本：

- 只接受 HTTPS 网络图片；本地路径和 `file://` 仅用于离线复现。
- 使用 macOS Vision 识别简体中文、繁体中文和英文，并输出逐图 JSONL、文本和置信度。
- 单图限制 20 MB；单个下载、解码或 OCR 失败只写入该图的错误记录，不掩盖其他图片的结果。
- 不读取浏览器 Cookie，不调用微信登录，不处理验证码，也不启用 HTTP。

编译和运行：

```sh
mkdir -p .module-cache
CLANG_MODULE_CACHE_PATH="$PWD/.module-cache" swiftc scripts/vision_ocr.swift -o .module-cache/vision_ocr
python3 scripts/read_wechat.py "https://mp.weixin.qq.com/s/..." > article.jsonl
# 从 article.jsonl 提取 image_urls 后，每行一个 URL：
.module-cache/vision_ocr < image_urls.txt > ocr.jsonl
```

如果当前主机没有可用的 Vision 文字识别运行时，保留逐图错误并转用 Codex 的视觉读取能力；不能把下载成功误报为 OCR 成功。
