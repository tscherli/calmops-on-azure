"""Tests for api.py -- the web API.

The same guarantees as the window and the terminal, checked over HTTP: consent
first, the crisis gate before any model call, and nothing written without an
answer on the approval card. The pause tests use the real graph with a scripted
model, because the pause and the resume are exactly what HTTP splits apart.
"""
import shutil

import pytest
from fastapi.testclient import TestClient
from langchain_core.messages import AIMessage
from langgraph.checkpoint.memory import InMemorySaver

import api
from agent.common import tool_event
from agent.data_paths import data_paths
from agent.graph import build_agent
from agent.safety import CONTENT_FILTERED_REPLY, CRISIS_RESOURCES
from observability.tracing import RunRecorder
from tests.conftest import StubChatModel
from tests.test_cli import PoisonGraph, StubGraph
from tools import measures
from tools.checkin_log import append_checkin_row, read_checkin_rows


@pytest.fixture
def paths(tmp_path):
    chosen = data_paths(tmp_path)
    shutil.copyfile(measures.MEASURES_PATH, chosen.measures)
    return chosen


def app_for(paths, graph):
    return api.create_app(graph=graph, paths=paths, recorder=RunRecorder(log_path=paths.runs_log))


def client_for(paths, graph=None, *, consent=True):
    client = TestClient(app_for(paths, graph or StubGraph()))
    if consent:
        client.post("/consent")
    return client


NEW_MEASURE = {
    "measure_id": "walk_outside",
    "measure": "Walk around the block",
    "measure_type": "recover",
    "fits_energy": ["wired"],
    "effort": "minutes",
}


def wants_to_add(paths):
    """The real graph, with a model that proposes one write and then replies."""
    model = StubChatModel(
        responses=[
            AIMessage(
                content="",
                tool_calls=[{"name": "add_measure", "id": "call_1", "args": NEW_MEASURE, "type": "tool_call"}],
            ),
            AIMessage(content="Done."),
        ]
    )
    return build_agent(
        model=model,
        checkpointer=InMemorySaver(),
        log_path=paths.checkin_log,
        measures_path=paths.measures,
    )


def listed(paths) -> dict[str, str]:
    return {row["measure_id"]: row["measure"] for row in measures.read_measures(paths.measures)}


def texts(view, kind) -> list[str]:
    return [item["text"] for item in view["items"] if item["kind"] == kind]


# -- what must work with nothing else ready ----------------------------------


def test_health_needs_neither_consent_nor_the_agent(paths):
    """The platform's probe calls this: it must not cost a model call."""
    graph = PoisonGraph()
    client = client_for(paths, graph, consent=False)

    response = client.get("/health")

    assert response.status_code == 200
    assert response.json() == {"status": "ok"}
    assert graph.attempts == 0


def test_the_page_is_served_and_never_builds_html_from_text(paths):
    """Replies can quote web pages, so they may only reach the page as text."""
    response = client_for(paths).get("/")

    assert response.status_code == 200
    assert "<title>CalmOps</title>" in response.text
    assert "innerHTML" not in response.text


def test_the_buttons_come_from_the_schema(paths):
    state = client_for(paths).get("/state").json()

    assert state["energy_options"] == ["exhausted", "calm", "wired"]
    assert state["goal_options"] == ["calm down now", "plan recovery", "change the situation"]
    assert [r["value"] for r in state["ratings"]] == ["helped", "somewhat", "didnt_help"]


# -- consent -----------------------------------------------------------------


def test_nothing_reaches_the_agent_before_consent(paths):
    graph = PoisonGraph()
    client = client_for(paths, graph, consent=False)

    assert "Microsoft Azure" in client.get("/state").json()["consent_text"]
    assert client.post("/chat", json={"message": "hello"}).status_code == 403
    assert client.post("/choice", json={"field": "energy", "value": "calm"}).status_code == 403
    assert client.post("/rate", json={"value": "helped"}).status_code == 403
    assert client.post("/approve", json={"decisions": []}).status_code == 403
    assert graph.attempts == 0


def test_consent_is_remembered(paths):
    client = client_for(paths, consent=False)

    client.post("/consent")

    assert paths.consent.exists()
    assert client.get("/state").json()["consent_text"] is None
    assert client.post("/chat", json={"message": "hello"}).status_code == 200


# -- a turn ------------------------------------------------------------------


def test_a_crisis_message_never_reaches_the_graph(paths):
    graph = PoisonGraph()

    view = client_for(paths, graph).post("/chat", json={"message": "I want to kill myself"}).json()

    assert texts(view, "notice") == [CRISIS_RESOURCES]
    assert graph.attempts == 0


def test_the_receipt_comes_before_the_reply(paths):
    """The evidence should never trail the claim, here as in the window."""
    event = tool_event("log_checkin", "ok", "row 1234", call_id="c1")
    client = client_for(paths, StubGraph(reply="All logged.", events=[event]))

    view = client.post("/chat", json={"message": "hello"}).json()

    assert [item["kind"] for item in view["items"]] == ["receipt", "reply"]
    assert "row 1234" in view["items"][0]["text"]
    assert view["items"][1]["text"] == "All logged."


def test_the_conversation_is_carried_to_the_next_turn(paths):
    graph = StubGraph()
    client = client_for(paths, graph)

    client.post("/chat", json={"message": "first"})
    client.post("/chat", json={"message": "second"})

    assert [m.content for m in graph.payloads[1]["messages"]] == ["first", "Stub reply", "second"]


@pytest.mark.parametrize("message", ["", "   ", "x" * (api.MAX_TEXT + 1)])
def test_an_empty_or_huge_message_is_refused(paths, message):
    graph = PoisonGraph()

    response = client_for(paths, graph).post("/chat", json={"message": message})

    assert response.status_code == 422
    assert graph.attempts == 0


class RaisingGraph:
    def __init__(self, exc):
        self.exc = exc

    def stream(self, *args, **kwargs):
        raise self.exc


def test_an_error_shows_no_details_to_the_browser(paths):
    client = client_for(paths, RaisingGraph(RuntimeError("https://secret.example/openai 401")))

    view = client.post("/chat", json={"message": "hello"}).json()

    assert texts(view, "notice") == [api.FAILURE_TEXT]
    assert "secret" not in str(view)


def test_a_content_filter_block_gets_its_clear_message(paths):
    error = RuntimeError("blocked")
    error.code = "content_filter"
    error.body = {"content_filters": []}

    view = client_for(paths, RaisingGraph(error)).post("/chat", json={"message": "hello"}).json()

    assert texts(view, "notice") == [CONTENT_FILTERED_REPLY]


# -- the approval card -------------------------------------------------------


def test_a_write_stops_at_the_card_and_runs_only_after_approval(paths):
    client = client_for(paths, wants_to_add(paths))

    view = client.post("/chat", json={"message": "add a walk"}).json()

    assert [c["id"] for c in view["card"]] == ["call_1"]
    assert view["card"][0]["description"] == 'Add to your list: "Walk around the block"'
    assert view["card"][0]["editable_text"] == "Walk around the block"
    assert "walk_outside" not in listed(paths)

    view = client.post("/approve", json={"decisions": [{"id": "call_1", "type": "approve"}]}).json()

    assert view["card"] == []
    assert texts(view, "reply") == ["Done."]
    assert listed(paths)["walk_outside"] == "Walk around the block"


def test_a_rejection_writes_nothing(paths):
    client = client_for(paths, wants_to_add(paths))
    client.post("/chat", json={"message": "add a walk"})

    client.post("/approve", json={"decisions": [{"id": "call_1", "type": "reject"}]})

    assert "walk_outside" not in listed(paths)


def test_an_edit_changes_only_the_editable_field(paths):
    client = client_for(paths, wants_to_add(paths))
    client.post("/chat", json={"message": "add a walk"})

    client.post(
        "/approve",
        json={"decisions": [{"id": "call_1", "type": "edit", "text": "Walk in the park", "args": {"measure_id": "x"}}]},
    )

    assert listed(paths)["walk_outside"] == "Walk in the park"
    assert "x" not in listed(paths)


def request(**overrides):
    return {"id": "w1", "args": {"measure": "old", "effort": "minutes"}, "editable": "measure", **overrides}


@pytest.mark.parametrize(
    "answers",
    [
        [],
        [api.Decision(id="someone_else", type="approve")],
        [api.Decision(id="w1", type="edit", text="")],
        [api.Decision(id="w1", type="reject")],
    ],
)
def test_anything_unclear_is_a_rejection(answers):
    assert api.decisions_for({"action_requests": [request()]}, answers) == [{"id": "w1", "type": "reject"}]


def test_a_card_without_an_editable_field_cannot_be_edited():
    answers = [api.Decision(id="w1", type="edit", text="new")]

    decisions = api.decisions_for({"action_requests": [request(editable=None)]}, answers)

    assert decisions == [{"id": "w1", "type": "reject"}]


def test_the_card_comes_back_after_a_page_reload(paths):
    client = client_for(paths, wants_to_add(paths))
    client.post("/chat", json={"message": "add a walk"})

    assert [c["id"] for c in client.get("/state").json()["card"]] == ["call_1"]


def test_nothing_else_runs_while_the_card_is_open(paths):
    client = client_for(paths, wants_to_add(paths))
    client.post("/chat", json={"message": "add a walk"})

    assert client.post("/chat", json={"message": "something else"}).status_code == 409
    assert client.post("/choice", json={"field": "energy", "value": "calm"}).status_code == 409
    assert client.post("/rate", json={"value": "helped"}).status_code == 409


def test_the_crisis_gate_answers_while_the_card_is_open_and_the_card_survives(paths):
    client = client_for(paths, wants_to_add(paths))
    client.post("/chat", json={"message": "add a walk"})

    view = client.post("/chat", json={"message": "I want to kill myself"}).json()

    assert texts(view, "notice") == [CRISIS_RESOURCES]
    assert [c["id"] for c in view["card"]] == ["call_1"]
    view = client.post("/approve", json={"decisions": [{"id": "call_1", "type": "approve"}]}).json()
    assert texts(view, "reply") == ["Done."]


def test_approve_with_nothing_waiting_is_refused(paths):
    assert client_for(paths).post("/approve", json={"decisions": []}).status_code == 409


class PausesThenFails:
    def stream(self, graph_input, config=None, stream_mode=None):
        if isinstance(graph_input, dict):
            pause = type("Interrupt", (), {"value": {"action_requests": [request(description="Write it")]}})
            yield ("updates", {"__interrupt__": (pause,)})
            return
        raise RuntimeError("the resume failed")


def test_a_failed_resume_closes_the_card(paths):
    client = client_for(paths, PausesThenFails())
    client.post("/chat", json={"message": "write"})

    view = client.post("/approve", json={"decisions": [{"id": "w1", "type": "approve"}]}).json()

    assert view["card"] == []
    assert client.post("/chat", json={"message": "hello again"}).status_code == 200


# -- the buttons -------------------------------------------------------------


def test_the_energy_and_goal_buttons_run_a_turn_marked_as_a_click(paths):
    graph = StubGraph()
    client = client_for(paths, graph)

    first = client.post("/choice", json={"field": "energy", "value": "wired"}).json()
    second = client.post("/choice", json={"field": "goal", "value": "calm down now"}).json()

    assert first["show_choices"] is True
    assert second["show_choices"] is False
    assert graph.payloads[1]["energy"] == "wired"
    assert graph.payloads[1]["goal"] == "calm down now"
    assert graph.payloads[1]["choices_clicked"] is True


def test_a_rating_writes_its_row_without_the_graph(paths):
    append_checkin_row(energy="wired", circumstances="a long day", measure_id="m01", path=paths.checkin_log)
    graph = PoisonGraph()
    client = client_for(paths, graph)
    assert client.get("/state").json()["rate_measure"] == "m01"

    view = client.post("/rate", json={"value": "didnt_help"}).json()

    assert graph.attempts == 0
    assert view["rate_measure"] is None
    assert read_checkin_rows(paths.checkin_log)[-1]["helpfulness"] == "didnt_help"


def test_an_unknown_rating_is_refused(paths):
    assert client_for(paths).post("/rate", json={"value": "great"}).status_code == 422


# -- one session per browser -------------------------------------------------


def test_two_browsers_have_two_conversations(paths):
    app = app_for(paths, StubGraph())
    first, second = TestClient(app), TestClient(app)
    first.post("/consent")

    first.post("/choice", json={"field": "energy", "value": "wired"})
    first.post("/choice", json={"field": "goal", "value": "plan recovery"})

    assert first.get("/state").json()["show_choices"] is False
    assert second.get("/state").json()["show_choices"] is True
    assert len(app.state.sessions) == 2


def test_the_cookie_cannot_be_read_by_scripts_or_sent_from_other_sites(paths):
    cookie = client_for(paths, consent=False).get("/state").headers["set-cookie"].lower()

    assert "httponly" in cookie
    assert "samesite=strict" in cookie
    assert "secure" not in cookie


def test_the_cookie_is_https_only_behind_the_https_proxy(paths):
    client = client_for(paths, consent=False)

    cookie = client.get("/state", headers={"x-forwarded-proto": "https"}).headers["set-cookie"]

    assert "secure" in cookie.lower()


def test_a_second_request_during_a_turn_is_refused(paths):
    """Two turns at once would overwrite each other's state."""
    app = app_for(paths, StubGraph())
    client = TestClient(app)
    client.post("/consent")
    client.post("/chat", json={"message": "first"})
    session = next(iter(app.state.sessions.values()))

    with session.lock:
        response = client.post("/chat", json={"message": "second"})

    assert response.status_code == 409
