"""Minimal MCP server for learning purposes.

Exposes this blog's Markdown posts (content/posts/) as MCP tools:
list_posts, get_post, search_by_tag. Not part of the production build —
run it standalone or point an MCP client (e.g. Claude Desktop) at it.
"""
import re
from pathlib import Path

import yaml
from mcp.server.mcpserver import MCPServer

POSTS_DIR = Path(__file__).resolve().parent.parent / "content" / "posts"

mcp = MCPServer("blog-posts")

FRONT_MATTER_RE = re.compile(r"^---\n(.*?)\n---\n(.*)$", re.DOTALL)


def _parse_post(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    match = FRONT_MATTER_RE.match(text)
    if not match:
        return {
            "slug": path.stem,
            "title": path.stem,
            "date": "",
            "tags": [],
            "draft": False,
            "body": text.strip(),
        }

    front_matter = yaml.safe_load(match.group(1)) or {}
    return {
        "slug": path.stem,
        "title": front_matter.get("title", path.stem),
        "date": str(front_matter.get("date", "")),
        "tags": front_matter.get("tags", []),
        "draft": bool(front_matter.get("draft", False)),
        "body": match.group(2).strip(),
    }


def _all_posts() -> list[dict]:
    return [_parse_post(p) for p in sorted(POSTS_DIR.glob("*.md"))]


@mcp.tool()
def list_posts(include_drafts: bool = False) -> list[dict]:
    """List all blog posts with title, date, tags and slug (body text omitted)."""
    posts = _all_posts()
    if not include_drafts:
        posts = [p for p in posts if not p["draft"]]
    return [{k: v for k, v in p.items() if k != "body"} for p in posts]


@mcp.tool()
def get_post(slug: str) -> dict:
    """Get the full content of one post by its filename slug (without .md)."""
    for post in _all_posts():
        if post["slug"] == slug:
            return post
    raise ValueError(f"No post found with slug '{slug}'")


@mcp.tool()
def search_by_tag(tag: str) -> list[dict]:
    """List non-draft posts that have the given tag."""
    return [
        {k: v for k, v in p.items() if k != "body"}
        for p in _all_posts()
        if not p["draft"] and tag in p.get("tags", [])
    ]


if __name__ == "__main__":
    mcp.run()
