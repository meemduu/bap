"""
GiDA FastAPI Server — Ana uygulama.

Web trafiği içeriklerini Android Accessibility Service'ten alıp kaydeder.
"""

import uuid
from contextlib import asynccontextmanager
from datetime import datetime

from fastapi import Depends, FastAPI, Query
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from database import CapturedContent, get_session, init_db
from models import ContentCreate, ContentLogItem, ContentLogResponse, ContentResponse


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Uygulama başlangıcında DB'yi hazırla."""
    await init_db()
    yield


app = FastAPI(
    title="GiDA Content Server",
    description="Android Accessibility Service'ten gelen web trafiği içeriklerini kaydeder.",
    version="0.1.0",
    lifespan=lifespan,
)


@app.get("/")
async def root():
    """Sağlık kontrolü."""
    return {"status": "ok", "service": "gida-content-server", "version": "0.1.0"}


@app.post("/api/v1/content", response_model=ContentResponse, status_code=201)
async def receive_content(
    payload: ContentCreate,
    session: AsyncSession = Depends(get_session),
):
    """Accessibility Service'ten gelen içeriği kaydet."""
    content_id = f"cnt_{uuid.uuid4().hex[:12]}"

    record = CapturedContent(
        content_id=content_id,
        device_id=payload.device_id,
        url=payload.url,
        page_title=payload.page_title,
        visible_text=payload.visible_text,
        browser_package=payload.browser_package,
        event_type=payload.event_type,
        timestamp=payload.timestamp,
    )
    session.add(record)
    await session.commit()

    return ContentResponse(
        content_id=content_id,
        status="received",
        timestamp=datetime.utcnow(),
    )


@app.get("/api/v1/logs", response_model=ContentLogResponse)
async def get_logs(
    device_id: str = Query(None, description="Cihaz ID'sine göre filtrele"),
    limit: int = Query(50, ge=1, le=500, description="Maksimum kayıt sayısı"),
    session: AsyncSession = Depends(get_session),
):
    """Kaydedilen içerikleri listele."""
    # Toplam sayı
    count_query = select(func.count(CapturedContent.id))
    if device_id:
        count_query = count_query.where(CapturedContent.device_id == device_id)
    total_result = await session.execute(count_query)
    total = total_result.scalar() or 0

    # Kayıtları getir
    query = select(CapturedContent).order_by(CapturedContent.timestamp.desc()).limit(limit)
    if device_id:
        query = query.where(CapturedContent.device_id == device_id)
    result = await session.execute(query)
    records = result.scalars().all()

    items = [
        ContentLogItem(
            content_id=r.content_id,
            url=r.url,
            page_title=r.page_title,
            timestamp=r.timestamp,
            browser_package=r.browser_package,
        )
        for r in records
    ]

    return ContentLogResponse(total=total, items=items)
