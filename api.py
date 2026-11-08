"""The web API: the same agent as app.py and cli.py, reached over HTTP.

A server has no window, so the browser talks to it in requests. Everything the
agent guarantees stays in the code both other clients use: this file wraps
cli.py's Session and adds only what HTTP needs.

    GET  /          the chat page
    GET  /health    is the process up? (no model call, no files)
    GET  /state     what the page should show after a load
    POST /consent   the first-use disclaimer was accepted
    POST /chat      a typed message
    POST /choice    an energy or goal button
    POST /approve   the answers to the approval card
    POST /rate      a rating button

One browser is one Session, found by a cookie. Sessions live in this process's
memory and never expire: there is one user and one replica, and a restart ends
them. That memory is also why the app must run on one replica only -- a click
on the card has to reach the process that holds the paused turn.

The endpoints are plain `def`, not `async def`: a turn blocks for seconds on the
model, and FastAPI runs plain functions on worker threads, so /health still
answers while one is running.

Entry point -- loads .env itself (same reason as app.py). Start it with:

    uvicorn api:create_app --factory --port 8000
"""
import json
import logging
import secrets
from collections.abc import Iterator
from contextlib import contextmanager
from pathlib import Path
from threading import Lock
from typing import Annotated, Any, Literal

from dotenv import load_dotenv

load_dotenv()

from fastapi import Depends, FastAPI, HTTPException, Request, Response
from fastapi.responses import FileResponse
from langgraph.checkpoint.memory import InMemorySaver
from pydantic import BaseModel, StringConstraints

from agent.common import format_tool_event
from agent.data_paths import DataPaths, data_paths, prepare
from agent.graph import build_agent
from agent.safety import content_filter_reply, screen_for_crisis
from cli import ENERGY_OPTIONS, GOAL_OPTIONS, RATINGS, Session
from observability.tracing import RunRecorder
from tools.checkin_log import Helpfulness

logger = logging.getLogger("calmops.api")

PAGE = Path(__file__).resolve().parent / "static" / "index.html"
SESSION_COOKIE = "calmops_session"
MAX_TEXT = 4000

RATING_LABELS = {"helped": "helped", "somewhat": "somewhat", "didnt_help": "not helpful"}

# The window's disclaimer says the data stays on the user's machine and goes to
# OpenAI. Neither is true here, so this is the same notice with the facts of
# the cloud version.
CONSENT_TEXT = (
    "Data & Privacy Disclaimer\n\n"
    "This tool sends what you type -- including personal reflections on how you are "
    "doing and what is going on at work -- to an AI model on Microsoft Azure, and to "
    "LangSmith if tracing is turned on. Azure may process it in any region, not only "
    "in Germany. When the agent looks for ideas beyond your own list it may also run "
    "a web search, and the search query then goes to a search service outside this "
    "app.\n\n"
    "Your check-in log and your list of measures are plain CSV files in this app's "
    "own storage. Their contents are included in what goes to the model while you "
    "are having a conversation.\n\n"
    "The rating buttons write straight to your log without asking the model. "
    "Everything else, what you type and the energy and goal buttons, is sent.\n\n"
    "Nothing else is written to your log or your list of measures without you: when "
    "the agent wants to, it shows exactly what it would write and waits for you to "
    "approve, edit or reject it.\n\n"
    "If you are not comfortable with a large language model processing your personal "
    "information, do not use this software.\n\n"
    "This is a self-reflection aid, not a substitute for professional mental health "
    "support; its replies are AI-generated and may be inaccurate. In a crisis, "
    "contact local emergency services or a crisis hotline directly, not this tool."
)

# The exception's own text can name endpoints and request details, and unlike
# the terminal this page is reachable from outside. It goes to the server's log.
# It does not say "nothing was saved": a write may have run before the failure.
FAILURE_TEXT = "Something went wrong and I couldn't process that. Please try again."

Text = Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=MAX_TEXT)]


class ChatBody(BaseModel):
    message: Text


class ChoiceBody(BaseModel):
    field: Literal["energy", "goal"]
    value: str


class RateBody(BaseModel):
    value: Helpfulness


class Decision(BaseModel):
    id: str
    type: Literal["approve", "edit", "reject"]
    text: Annotated[str, StringConstraints(strip_whitespace=True, max_length=MAX_TEXT)] = ""


class ApproveBody(BaseModel):
    decisions: list[Decision]


class WebSession(Session):
    """A Session whose turn stops at the approval card and whose output is
    collected for the response instead of printed."""

    def __init__(self, graph: Any, *, log_path: Path, recorder: RunRecorder) -> None:
        self.items: list[dict[str, Any]] = []
        super().__init__(graph, log_path=log_path, recorder=recorder, out=self._show_notice)
        # Two turns at once would overwrite each other's state.
        self.lock = Lock()

    def run_turn(self, text: str, **extra: Any) -> None:
        self.start_turn(text, **extra)

    def _show_notice(self, text: str) -> None:
        self.items.append({"kind": "notice", "text": text.strip()})

    def _show_receipt(self, event: dict) -> None:
        self.items.append(
            {
                "kind": "receipt",
                "text": format_tool_event(event).strip(),
                "failed": event.get("exit_code") == 1,
            }
        )

    def _show_reply(self, text: str, result: dict, latency: float) -> None:
        self.items.append({"kind": "reply", "text": text})

    def _failure_text(self, exc: Exception) -> str:
        reply = content_filter_reply(exc)
        if reply is None:
            logger.error("A turn failed", exc_info=exc)
            return FAILURE_TEXT
        return reply

    def controls(self) -> dict[str, Any]:
        """What can be clicked right now, the same rules as the window's."""
        return {
            "card": [
                {
                    "id": request.get("id", ""),
                    "description": request.get("description", ""),
                    "editable_text": (
                        str((request.get("args") or {}).get(request["editable"], ""))
                        if request.get("editable")
                        else None
                    ),
                }
                for request in (self.paused or {}).get("action_requests") or []
            ],
            "show_choices": not (self.state.get("energy") and self.state.get("goal")),
            "rate_measure": self.last_measure_id or None,
        }

    def view(self) -> dict[str, Any]:
        """The response to a request: what happened, then what can be clicked."""
        items, self.items = self.items, []
        return {"items": items, **self.controls()}


def decisions_for(paused: dict, answers: list[Decision]) -> list[dict]:
    """The browser's answers as the graph's decisions, one per pending write.

    Built from the paused request, not from what the browser sends: it can name
    a call and change the one field the card lets it edit, nothing else.
    Anything but a clear approve or a non-empty edit is a rejection, because a
    write must never happen because an answer was unclear.
    """
    by_id = {answer.id: answer for answer in answers}
    decisions: list[dict] = []
    for request in paused.get("action_requests") or []:
        call_id = request.get("id", "")
        answer = by_id.get(call_id)
        editable = request.get("editable")
        if answer is not None and answer.type == "approve":
            decisions.append({"id": call_id, "type": "approve"})
        elif answer is not None and answer.type == "edit" and editable and answer.text:
            args = {**(request.get("args") or {}), editable: answer.text}
            decisions.append({"id": call_id, "type": "edit", "args": args})
        else:
            decisions.append({"id": call_id, "type": "reject"})
    return decisions


@contextmanager
def one_at_a_time(session: WebSession) -> Iterator[None]:
    """Refuse a second request while this browser's turn is running."""
    if not session.lock.acquire(blocking=False):
        raise HTTPException(409, "I'm still working on your last message.")
    try:
        yield
    finally:
        session.lock.release()


def refuse_while_card_open(session: WebSession) -> None:
    if session.paused is not None:
        raise HTTPException(409, "Please answer the approval card first.")


def create_app(
    *,
    graph: Any = None,
    paths: DataPaths | None = None,
    recorder: RunRecorder | None = None,
) -> FastAPI:
    """Build the app. Everything injectable, so the tests run the real
    endpoints without Azure and without touching the real log."""
    if paths is None:
        paths = prepare(data_paths())
    # One graph for all sessions: each turn runs on a thread of its own.
    if graph is None:
        graph = build_agent(
            checkpointer=InMemorySaver(), log_path=paths.checkin_log, measures_path=paths.measures
        )
    if recorder is None:
        recorder = RunRecorder(log_path=paths.runs_log)

    app = FastAPI(title="CalmOps")
    sessions: dict[str, WebSession] = {}
    app.state.sessions = sessions

    def session_for(request: Request, response: Response) -> WebSession:
        session = sessions.get(request.cookies.get(SESSION_COOKIE, ""))
        if session is None:
            session_id = secrets.token_urlsafe(32)
            session = sessions[session_id] = WebSession(graph, log_path=paths.checkin_log, recorder=recorder)
            # Container Apps ends HTTPS in front of the app and says so in
            # this header; the app itself only sees plain HTTP.
            https = request.headers.get("x-forwarded-proto", request.url.scheme) == "https"
            response.set_cookie(SESSION_COOKIE, session_id, httponly=True, samesite="strict", secure=https)
        return session

    CurrentSession = Annotated[WebSession, Depends(session_for)]

    def require_consent() -> None:
        if not paths.consent.exists():
            raise HTTPException(403, "Please accept the disclaimer first.")

    consented = [Depends(require_consent)]

    @app.get("/", include_in_schema=False)
    def page() -> FileResponse:
        return FileResponse(PAGE)

    @app.get("/health")
    def health() -> dict[str, str]:
        return {"status": "ok"}

    @app.get("/state")
    def state(session: CurrentSession) -> dict[str, Any]:
        has_consent = paths.consent.exists()
        return {
            **session.controls(),
            "consent_text": None if has_consent else CONSENT_TEXT,
            "energy_options": ENERGY_OPTIONS,
            "goal_options": GOAL_OPTIONS,
            "ratings": [{"value": value, "label": RATING_LABELS[value]} for value in RATINGS],
            "max_text": MAX_TEXT,
        }

    @app.post("/consent")
    def consent() -> dict[str, bool]:
        paths.consent.parent.mkdir(parents=True, exist_ok=True)
        paths.consent.write_text(json.dumps({"acknowledged": True}), encoding="utf-8")
        return {"acknowledged": True}

    @app.post("/chat", dependencies=consented)
    def chat(body: ChatBody, session: CurrentSession) -> dict[str, Any]:
        with one_at_a_time(session):
            # The crisis gate answers even while a card is open: start_turn
            # stops at the gate and leaves the paused turn as it is.
            if not screen_for_crisis(body.message).triggered:
                refuse_while_card_open(session)
            session.start_turn(body.message)
            return session.view()

    @app.post("/choice", dependencies=consented)
    def choice(body: ChoiceBody, session: CurrentSession) -> dict[str, Any]:
        with one_at_a_time(session):
            refuse_while_card_open(session)
            session.handle(f"/{body.field} {body.value}")
            return session.view()

    @app.post("/approve", dependencies=consented)
    def approve(body: ApproveBody, session: CurrentSession) -> dict[str, Any]:
        with one_at_a_time(session):
            if session.paused is None:
                raise HTTPException(409, "Nothing is waiting for your approval.")
            session.resume_turn(decisions_for(session.paused, body.decisions))
            return session.view()

    @app.post("/rate", dependencies=consented)
    def rate(body: RateBody, session: CurrentSession) -> dict[str, Any]:
        with one_at_a_time(session):
            refuse_while_card_open(session)
            session.handle(f"/rate {body.value}")
            return session.view()

    return app
