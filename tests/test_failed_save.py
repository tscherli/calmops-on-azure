"""A save that ran and failed: code says so first (case 39, failure A).

On Azure, one run of 8 answered a failed rating with "Thanks -- I recorded
that box breathing helped." (2026-11-05). Now the tool says plainly that
nothing was saved, the model gets a note at the end of its context, and the
reply opens with SAVE_FAILED_LINE, written by code. The write fails for real
here, the way the eval case makes it fail: the log's parent is a file.
"""
import csv

import pytest
from langchain_core.messages import AIMessage, HumanMessage, SystemMessage, ToolMessage
from langgraph.checkpoint.memory import InMemorySaver

from agent.graph import build_agent
from agent.prompts import SAVE_FAILED_LINE, SAVE_FAILED_NOTE
from tests.conftest import StubChatModel, invoke_approving
from tools.measures import MEASURE_COLUMNS

FOLLOW_UP = {
    "energy": "exhausted", "goal": "calm down now", "situation": "third late night this week",
    "offered": ["breathe"], "step": "follow_up",
}
LOG_CALL = AIMessage(content="", tool_calls=[{
    "name": "log_checkin",
    "args": {"energy": "exhausted", "circumstances": "third late night this week", "measure_id": "breathe"},
    "id": "log1",
}])


@pytest.fixture
def measures_file(tmp_path):
    path = tmp_path / "measures.csv"
    with path.open("w", encoding="utf-8", newline="") as handle:
        writer = csv.writer(handle, lineterminator="\n")
        writer.writerow(MEASURE_COLUMNS)
        writer.writerow(("breathe", "recover", "Take a few slow breaths.", "exhausted;calm;wired", "minutes", "user"))
    return path


@pytest.fixture
def broken_log(tmp_path):
    blocker = tmp_path / "not-a-directory"
    blocker.write_text("blocks the write below", encoding="utf-8")
    return blocker / "checkin_log.csv"


def run(log_path, measures_file, *replies, state=None):
    stations = StubChatModel(responses=list(replies))
    graph = build_agent(model=stations, log_path=log_path, measures_path=measures_file,
                        checkpointer=InMemorySaver())
    result = invoke_approving(graph, {"messages": [HumanMessage(content="yeah log that")],
                                      **FOLLOW_UP, **(state or {})})
    return result, stations


def test_a_failed_save_opens_the_reply_with_the_fixed_line(broken_log, measures_file):
    result, _ = run(broken_log, measures_file, LOG_CALL, AIMessage(content="Thanks -- I recorded that."))

    assert result["save_failed"] is True
    assert result["messages"][-1].content == f"{SAVE_FAILED_LINE}\n\nThanks -- I recorded that."


def test_the_model_reads_the_note_last(broken_log, measures_file):
    _, stations = run(broken_log, measures_file, LOG_CALL, AIMessage(content="Sorry about that."))

    after_the_failure = stations.received_messages[-1]
    assert isinstance(after_the_failure[-1], SystemMessage)
    assert SAVE_FAILED_NOTE in after_the_failure[-1].content
    # ... and not before the write, when nothing had failed yet.
    assert all(SAVE_FAILED_NOTE not in str(m.content) for m in stations.received_messages[0])


def test_the_tool_says_plainly_that_nothing_was_saved(broken_log, measures_file):
    result, _ = run(broken_log, measures_file, LOG_CALL, AIMessage(content="ok"))

    message = next(m for m in result["messages"] if isinstance(m, ToolMessage) and m.name == "log_checkin")
    assert message.status == "error"
    assert message.content.startswith("NOT saved")
    # The old text ended "saved to the pending file"; the model built a claim on it.
    assert "saved to" not in message.content
    event = next(e for e in result["tool_events"] if e["tool"] == "log_checkin")
    assert event["exit_code"] != 0 and event["detail"].startswith("write failed")


def test_a_save_that_worked_gets_neither(tmp_path, measures_file):
    result, stations = run(tmp_path / "log.csv", measures_file, LOG_CALL, AIMessage(content="Logged it."))

    assert not result.get("save_failed")
    assert result["messages"][-1].content == "Logged it."
    assert all(SAVE_FAILED_NOTE not in str(m.content) for call in stations.received_messages for m in call)


def test_a_retry_the_model_asks_for_carries_no_line_until_it_replies(broken_log, measures_file):
    """The line goes on a reply, never on a tool call: the call stays as the
    model made it, and the card shows it."""
    retry = AIMessage(content="", tool_calls=[{**LOG_CALL.tool_calls[0], "id": "log2"}])
    result, _ = run(broken_log, measures_file, LOG_CALL, retry, AIMessage(content="Still no luck."))

    calls = [m for m in result["messages"] if isinstance(m, AIMessage) and m.tool_calls]
    assert len(calls) == 2 and all(not m.content for m in calls)
    assert result["messages"][-1].content == f"{SAVE_FAILED_LINE}\n\nStill no luck."


def test_the_next_turn_starts_without_it(tmp_path, measures_file):
    stations = StubChatModel(responses=[AIMessage(content="Glad to hear it.")])
    graph = build_agent(model=stations, log_path=tmp_path / "log.csv", measures_path=measures_file)

    result = graph.invoke({"messages": [HumanMessage(content="thanks")], **FOLLOW_UP, "save_failed": True})

    assert result["save_failed"] is False
    assert result["messages"][-1].content == "Glad to hear it."
