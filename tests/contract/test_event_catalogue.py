"""Keep docs/EVENT_CATALOGUE.md honest about the event types the runtime actually publishes."""

from __future__ import annotations

from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[2]
CATALOGUE = ROOT / "docs" / "EVENT_CATALOGUE.md"
CRATES = ROOT / "runtime" / "crates"

#: Call shapes that publish an event, including the daemon's own emit helpers, plus the two builders that name a type in a literal.
EMIT_CALL = re.compile(
    r"(?:emit|emit_on|emit_scoped|emit_event|emit_cluster_event|announce|publish_operation)\s*\(([^;]{0,800}?)\)\s*;",
    re.S,
)
EVENT_FIELD = re.compile(r'event_type:\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"')
TYPE_LITERAL = re.compile(r'"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"')
#: `terminal_event` maps a state to (event type, severity).
SEVERITY_TUPLE = re.compile(
    r'\(\s*"([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"\s*,\s*"(?:info|notice|warning|error|critical)"\s*\)'
)


#: Documented types with no producer in this runtime; each is marked "planned" in the catalogue, a client may not subscribe to one and expect anything, and a name comes out of here on the same commit that starts publishing it.
PLANNED_EVENT_TYPES = frozenset({
    "agent.approval.required",
    "agent.change.ready",
    "agent.failed",
    "agent.merged",
    "agent.plan.ready",
    "agent.started",
    "agent.test.completed",
    "agent.tool.requested",
    "build.log.chunk",
    "cluster.model.failed",
    "cluster.model.started",
    "guest.request.admitted",
    "guest.route.refused",
    "inference.request.cancelled",
    "inference.request.completed",
    "inference.request.failed",
    "inference.request.first_token",
    "inference.request.started",
    "inference.usage.recorded",
    "model.download.completed",
    "model.download.failed",
    "model.download.queued",
    "model.download.verifying",
    "model.load.preflight",
    "model.load.progress",
    "node.route.changed",
    "node.runtime.update.available",
    "node.runtime.update.completed",
    "node.runtime.update.failed",
    "node.runtime.update.progress",
    "node.status.changed",
    "operation.awaiting_approval",
    "pairing.invitation.claimed",
    "pairing.invitation.created",
    "pairing.invitation.expired",
    "project.container.started",
    "project.container.stopped",
    "project.file.changed",
    "project.preview.failed",
    "project.preview.ready",
    "security.tls.identity.mismatch",
    "shared_access.invitation.created",
    "web.fetch.performed",
    "web.fetch.refused",
    "web.personal_context.stripped",
    "web.robots.checked",
    "web.search.performed",
    "web.search.refused",
})


def is_production_source(path: Path) -> bool:
    """Skip test sources so a fixture event name never becomes a documentation obligation."""
    parts = path.parts
    return "tests" not in parts and not path.name.endswith("tests.rs")


def emitted_event_types() -> dict[str, set[str]]:
    found: dict[str, set[str]] = {}
    for source in sorted(CRATES.rglob("*.rs")):
        if not is_production_source(source):
            continue
        text = source.read_text(encoding="utf-8", errors="ignore")
        names: set[str] = set()
        for call in EMIT_CALL.finditer(text):
            names.update(TYPE_LITERAL.findall(call.group(1)))
        names.update(EVENT_FIELD.findall(text))
        names.update(SEVERITY_TUPLE.findall(text))
        for name in names:
            found.setdefault(name, set()).add(str(source.relative_to(ROOT)))
    return found


def documented_event_types() -> set[str]:
    text = CATALOGUE.read_text(encoding="utf-8")
    return set(re.findall(r"^- `([a-z][a-z0-9_.]+)`", text, re.MULTILINE))


class EventCatalogueTests(unittest.TestCase):
    def test_every_published_event_type_is_documented(self) -> None:
        emitted = emitted_event_types()
        documented = documented_event_types()
        undocumented = {
            name: sorted(sources)
            for name, sources in emitted.items()
            if name not in documented
        }
        self.assertEqual(
            undocumented,
            {},
            "PLAN §60.2: a client subscribing to the catalogue would never learn about these. "
            "Add them to docs/EVENT_CATALOGUE.md, or stop publishing them.",
        )

    def test_every_documented_event_type_has_a_producer_or_is_planned(self) -> None:
        emitted = set(emitted_event_types())
        documented = documented_event_types()
        unproduced = sorted(documented - emitted - PLANNED_EVENT_TYPES)
        self.assertEqual(
            unproduced,
            [],
            "PLAN 60.2: the catalogue is what a client can subscribe to. Publish these, "
            "or add them to PLANNED_EVENT_TYPES and mark them planned in "
            "docs/EVENT_CATALOGUE.md.",
        )

    def test_the_planned_list_holds_nothing_that_is_now_published(self) -> None:
        emitted = set(emitted_event_types())
        published = sorted(PLANNED_EVENT_TYPES & emitted)
        self.assertEqual(
            published,
            [],
            "these are published now; take them out of PLANNED_EVENT_TYPES and out of the "
            "planned notes in docs/EVENT_CATALOGUE.md",
        )

    def test_every_planned_type_is_marked_planned_in_the_catalogue(self) -> None:
        text = CATALOGUE.read_text(encoding="utf-8")
        marked = set(
            re.findall(r"^- `([a-z][a-z0-9_.]+)`[^\n]*planned", text, re.MULTILINE)
        )
        self.assertEqual(
            sorted(PLANNED_EVENT_TYPES - marked),
            [],
            "a client reading the catalogue would think these are live",
        )
        self.assertEqual(
            sorted(marked - PLANNED_EVENT_TYPES),
            [],
            "these are marked planned but are not in PLANNED_EVENT_TYPES",
        )

    def test_the_catalogue_is_not_empty_and_parses(self) -> None:
        documented = documented_event_types()
        self.assertGreater(len(documented), 50, "the catalogue parser found almost nothing")
        self.assertIn("operation.progress", documented)

    def test_the_extractor_sees_the_publishers_it_claims_to_cover(self) -> None:
        emitted = emitted_event_types()
        # One representative of each shape the extractor understands.
        for name in ("operation.completed", "fabric.carrier_detected", "model.ready"):
            self.assertIn(name, emitted, f"the extractor stopped seeing {name}")


if __name__ == "__main__":
    unittest.main()
