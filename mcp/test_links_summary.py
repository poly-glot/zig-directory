"""The list_links headline, which a model reads as the answer to "how many".

The page total is the exact count of approved links, the same figure
browse_category shows, so the headline can say "of N approved links".
"""

from dmozdb_mcp.tools.links import _summarize


def test_headline_reports_the_page_against_the_approved_total() -> None:
    link = {"title": "Example", "url": "https://example.org/", "description": ""}
    page = {"links": [link] * 10, "total": 120, "nextAfterId": 0}

    headline, _ = _summarize(page, "Arts")

    assert headline == "10 of 120 approved links under Arts"
