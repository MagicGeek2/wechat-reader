#!/usr/bin/env python3
"""Read public WeChat articles when the response contains article HTML.

The script deliberately stops at WeChat's verification page. It does not
solve CAPTCHA challenges or try alternate endpoints to bypass them.
"""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import ssl
import sys
from html.parser import HTMLParser
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


DEFAULT_USER_AGENT = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
    "AppleWebKit/537.36 (KHTML, like Gecko) "
    "Chrome/131.0.0.0 Safari/537.36"
)
SYSTEM_CA_FILES = (
    "/etc/ssl/cert.pem",
    "/etc/ssl/certs/ca-certificates.crt",
    "/etc/pki/tls/certs/ca-bundle.crt",
)
VOID_TAGS = {
    "area",
    "base",
    "br",
    "col",
    "embed",
    "hr",
    "img",
    "input",
    "link",
    "meta",
    "param",
    "source",
    "track",
    "wbr",
}
BLOCK_TAGS = {"article", "blockquote", "div", "li", "p", "pre", "section", "tr"}
IMAGE_PATTERN = re.compile(
    r"cdn_url:\s*'((?:\\.|[^'])*)'\s*,\s*"
    r"width:\s*'?(\d+)'?.{0,100}?height:\s*'?(\d+)'?",
    re.DOTALL,
)
FALLBACK_IMAGE_PATTERN = re.compile(r"https?://(?:mmbiz|wx)\.qpic\.cn/[^\"'\\ ]+")


class ArticleParser(HTMLParser):
    """Extract visible text from the classic WeChat article container."""

    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self._content_depth = 0
        self._title_depth = 0
        self._author_depth = 0
        self._parts: list[str] = []
        self.title_parts: list[str] = []
        self.author_parts: list[str] = []

    @staticmethod
    def _attrs(attrs: list[tuple[str, str | None]]) -> dict[str, str]:
        return {name: value or "" for name, value in attrs}

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attr = self._attrs(attrs)
        element_id = attr.get("id", "")
        if element_id == "js_content":
            self._content_depth = 1
        elif self._content_depth and tag not in VOID_TAGS:
            self._content_depth += 1

        if element_id == "activity-name":
            self._title_depth = 1
        elif self._title_depth and tag not in VOID_TAGS:
            self._title_depth += 1
        if element_id == "js_name":
            self._author_depth = 1
        elif self._author_depth and tag not in VOID_TAGS:
            self._author_depth += 1

        if self._content_depth and tag in BLOCK_TAGS:
            self._parts.append("\n")

    def handle_startendtag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        if self._content_depth and tag in BLOCK_TAGS:
            self._parts.append("\n")

    def handle_endtag(self, tag: str) -> None:
        if self._content_depth:
            if tag in BLOCK_TAGS:
                self._parts.append("\n")
            if tag not in VOID_TAGS:
                self._content_depth -= 1
        if self._title_depth:
            self._title_depth -= 1
        if self._author_depth:
            self._author_depth -= 1

    def handle_data(self, data: str) -> None:
        value = " ".join(data.split())
        if not value:
            return
        if self._content_depth:
            self._parts.append(value)
        if self._title_depth:
            self.title_parts.append(value)
        if self._author_depth:
            self.author_parts.append(value)

    @property
    def body(self) -> str:
        return re.sub(r"[ \t]*\n[ \t]*", "\n", " ".join(self._parts)).strip()


def _meta(source: str, key: str) -> str:
    pattern = (
        r"<meta[^>]+(?:property|name)=[\"']"
        + re.escape(key)
        + r"[\"'][^>]+content=[\"']([^\"']*)"
    )
    match = re.search(pattern, source, re.IGNORECASE)
    return html.unescape(match.group(1)) if match else ""


def _cgi_value(source: str, key: str) -> str:
    # The shell response uses single-quoted JavaScript values and may encode
    # HTML entities as hexadecimal escapes (for example, \x26lt;).
    match = re.search(rf"(?:^|[,{{]\s*){re.escape(key)}\s*:\s*'((?:\\.|[^'])*)'", source)
    if not match:
        return ""
    value = match.group(1)
    try:
        value = bytes(value, "utf-8").decode("unicode_escape")
    except UnicodeDecodeError:
        pass
    return html.unescape(value)


def _normalise_image_url(value: str) -> str:
    value = value.replace("\\x26", "&").replace("\\u0026", "&").replace("\\x3d", "=")
    value = value.replace("\\/", "/")
    value = html.unescape(value)
    if value.startswith("http://mmbiz.qpic.cn/"):
        value = "https://" + value[len("http://") :]
    return value


def _image_urls(source: str) -> list[str]:
    """Extract article images from WeChat's image-only response shell."""
    urls: list[str] = []
    for match in IMAGE_PATTERN.finditer(source):
        url = _normalise_image_url(match.group(1))
        if url not in urls:
            urls.append(url)
    if urls:
        return urls
    for match in FALLBACK_IMAGE_PATTERN.finditer(source):
        url = _normalise_image_url(match.group(0))
        if url not in urls:
            urls.append(url)
    return urls


def _tls_context() -> ssl.SSLContext:
    """Use the platform CA store when Python was built without a CA path."""
    context = ssl.create_default_context()
    if context.get_ca_certs():
        return context
    for path in SYSTEM_CA_FILES:
        if os.path.exists(path):
            context.load_verify_locations(cafile=path)
            break
    return context


def read_article(url: str, timeout: int = 30) -> dict[str, object]:
    request = Request(url, headers={"User-Agent": DEFAULT_USER_AGENT, "Accept-Language": "zh-CN,zh;q=0.9"})
    try:
        with urlopen(request, timeout=timeout, context=_tls_context()) as response:
            final_url = response.geturl()
            source = response.read().decode("utf-8", errors="replace")
            status_code = response.status
    except HTTPError as exc:
        return {"url": url, "status": "http_error", "http_status": exc.code, "error": str(exc)}
    except URLError as exc:
        return {"url": url, "status": "network_error", "error": str(exc.reason)}

    captcha_markers = (
        "/mp/wappoc_appmsgcaptcha" in final_url
        or "环境异常" in source
        or "完成验证后即可继续访问" in source
        or "去验证" in source
    )
    if captcha_markers:
        return {
            "url": url,
            "final_url": final_url,
            "status": "captcha_required",
            "http_status": status_code,
        }

    parser = ArticleParser()
    parser.feed(source)
    title = "".join(parser.title_parts).strip() or _meta(source, "og:title") or _cgi_value(source, "title")
    author = "".join(parser.author_parts).strip()
    description = _meta(source, "description") or _meta(source, "og:description") or _cgi_value(source, "desc")
    body = parser.body
    image_urls = _image_urls(source)
    result: dict[str, object] = {
        "url": url,
        "final_url": final_url,
        "status": "ok" if body else "metadata_only",
        "http_status": status_code,
        "title": title,
        "author": author,
        "description": description,
    }
    if image_urls:
        result["image_count"] = len(image_urls)
        result["image_urls"] = image_urls
        if not body:
            result["status"] = "image_only"
    if body:
        result["content"] = body
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Read public WeChat article HTML")
    parser.add_argument("urls", nargs="+", help="WeChat article URLs")
    args = parser.parse_args(argv)
    for url in args.urls:
        print(json.dumps(read_article(url), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
