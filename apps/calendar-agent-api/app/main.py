import os
import time
from typing import Any

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Response, status
from pydantic import BaseModel, Field


GRAPH_BASE_URL = "https://graph.microsoft.com/v1.0"


class GraphTokenCache:
    def __init__(self) -> None:
        self._token: str | None = None
        self._expires_at = 0.0

    async def get(self) -> str:
        if self._token and time.time() < self._expires_at - 300:
            return self._token

        tenant_id = required_env("AZURE_TENANT_ID")
        client_id = required_env("AZURE_CLIENT_ID")
        client_secret = required_env("AZURE_CLIENT_SECRET")
        authority_host = os.getenv("AZURE_AUTHORITY_HOST", "https://login.microsoftonline.com").rstrip("/")
        token_url = f"{authority_host}/{tenant_id}/oauth2/v2.0/token"

        async with httpx.AsyncClient(timeout=20.0) as client:
            response = await client.post(
                token_url,
                data={
                    "client_id": client_id,
                    "client_secret": client_secret,
                    "scope": "https://graph.microsoft.com/.default",
                    "grant_type": "client_credentials",
                },
            )

        if response.status_code >= 400:
            raise HTTPException(status_code=502, detail={"message": "Microsoft token request failed"})

        payload = response.json()
        self._token = payload["access_token"]
        self._expires_at = time.time() + int(payload.get("expires_in", 3600))
        return self._token


class DateTimeTimeZone(BaseModel):
    dateTime: str = Field(..., examples=["2026-08-21T14:00:00"])
    timeZone: str = Field(default="Europe/Berlin")


class EventCreate(BaseModel):
    subject: str
    start: DateTimeTimeZone
    end: DateTimeTimeZone
    body: dict[str, str] | None = None
    location: dict[str, str] | None = None
    attendees: list[dict[str, Any]] | None = None


class EventPatch(BaseModel):
    subject: str | None = None
    start: DateTimeTimeZone | None = None
    end: DateTimeTimeZone | None = None
    body: dict[str, str] | None = None
    location: dict[str, str] | None = None
    attendees: list[dict[str, Any]] | None = None


token_cache = GraphTokenCache()
app = FastAPI(title="MIAK Calendar Agent API", version="0.1.0")


def required_env(name: str) -> str:
    value = os.getenv(name)
    if not value:
        raise HTTPException(status_code=500, detail=f"Missing environment variable {name}")
    return value


def require_api_key(x_api_key: str | None = Header(default=None)) -> None:
    if os.getenv("REQUIRE_API_KEY", "false").lower() != "true":
        return

    expected = required_env("API_KEY")
    if not x_api_key or x_api_key != expected:
        raise HTTPException(status_code=status.HTTP_401_UNAUTHORIZED, detail="Invalid API key")


async def graph_request(method: str, path: str, **kwargs: Any) -> Any:
    token = await token_cache.get()
    async with httpx.AsyncClient(timeout=30.0) as client:
        response = await client.request(
            method,
            f"{GRAPH_BASE_URL}{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            **kwargs,
        )

    if response.status_code == status.HTTP_204_NO_CONTENT:
        return Response(status_code=status.HTTP_204_NO_CONTENT)

    if response.status_code >= 400:
        detail = response.json() if response.headers.get("content-type", "").startswith("application/json") else response.text
        raise HTTPException(status_code=response.status_code, detail=detail)

    return response.json()


def calendar_user() -> str:
    return required_env("CALENDAR_USER_ID")


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.get("/events", dependencies=[Depends(require_api_key)])
async def list_events(
    start: str = Query(..., description="Start datetime, e.g. 2026-08-21T00:00:00"),
    end: str = Query(..., description="End datetime, e.g. 2026-08-22T00:00:00"),
    top: int = Query(default=50, ge=1, le=100),
) -> Any:
    return await graph_request(
        "GET",
        f"/users/{calendar_user()}/calendarView",
        params={
            "startDateTime": start,
            "endDateTime": end,
            "$top": str(top),
            "$orderby": "start/dateTime",
        },
    )


@app.post("/events", dependencies=[Depends(require_api_key)])
async def create_event(event: EventCreate) -> Any:
    return await graph_request(
        "POST",
        f"/users/{calendar_user()}/calendar/events",
        json=event.model_dump(exclude_none=True),
    )


@app.get("/events/{event_id}", dependencies=[Depends(require_api_key)])
async def get_event(event_id: str) -> Any:
    return await graph_request("GET", f"/users/{calendar_user()}/calendar/events/{event_id}")


@app.patch("/events/{event_id}", dependencies=[Depends(require_api_key)])
async def update_event(event_id: str, event: EventPatch) -> Any:
    return await graph_request(
        "PATCH",
        f"/users/{calendar_user()}/calendar/events/{event_id}",
        json=event.model_dump(exclude_none=True),
    )


@app.delete("/events/{event_id}", dependencies=[Depends(require_api_key)])
async def delete_event(event_id: str) -> Response:
    result = await graph_request("DELETE", f"/users/{calendar_user()}/calendar/events/{event_id}")
    if isinstance(result, Response):
        return result
    return Response(status_code=status.HTTP_204_NO_CONTENT)
