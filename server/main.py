"""
GiDA FastAPI Server — Ana uygulama.

Web trafiği içeriklerini ve yakalanan görselleri Android Accessibility Service'ten alıp kaydeder.
"""

import json
import os
import uuid
from contextlib import asynccontextmanager
from datetime import datetime
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.responses import FileResponse
from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from database import CapturedContent, CapturedImage, get_session, init_db
from models import (
    BlacklistRuleRequest,
    ContentCreate,
    ContentLogItem,
    ContentLogResponse,
    ContentResponse,
    ImageInfo,
)

STORAGE_DIR = Path(__file__).parent / "storage" / "images"
STORAGE_DIR.mkdir(parents=True, exist_ok=True)

# Dinamik kara liste kuralları (pattern -> reason)
BLACKLIST_RULES: dict[str, str] = {
    "example.com": "Test amaçlı engellenen site (example.com)",
    "zararli": "Zararlı içerik / alan adı tespit edildi",
    "kumar": "Yasadışı bahis / kumar içeriği tespit edildi",
    "bahis": "Yasadışı bahis içeriği tespit edildi",
    "casino": "Kumar / casino içeriği tespit edildi",
    "bet": "Bahis içeriği tespit edildi",
    "porn": "Yetişkin (+18) içerik tespit edildi",
    "xxx": "Yetişkin (+18) içerik tespit edildi",
}


def evaluate_content(payload: ContentCreate) -> tuple[bool, str]:
    """Gelen URL, başlık ve görünür metni inceleyip engellenip engellenmeyeceğine karar verir."""
    url_lower = (payload.url or "").lower()
    title_lower = (payload.page_title or "").lower()
    text_lower = (payload.visible_text or "").lower()

    # Önce URL ve başlık üzerinde tam/alt-dize kontrolü
    for pattern, reason in BLACKLIST_RULES.items():
        pat = pattern.lower().strip()
        if not pat:
            continue
        if pat in url_lower or pat in title_lower:
            return True, reason

    # Görünür metin kontrolü (kelime bazlı veya belirgin eşleşme)
    for pattern, reason in BLACKLIST_RULES.items():
        pat = pattern.lower().strip()
        if len(pat) >= 4 and pat in text_lower:
            return True, reason

    return False, ""


@asynccontextmanager
async def lifespan(app: FastAPI):
    """Uygulama başlangıcında DB'yi hazırla."""
    await init_db()
    yield


app = FastAPI(
    title="GiDA Content Server",
    description="Android Accessibility Service'ten gelen web trafiği içeriklerini ve görselleri kaydeder, zararlı siteleri engeller.",
    version="0.3.0",
    lifespan=lifespan,
)


@app.get("/")
async def root():
    """Sağlık kontrolü."""
    return {"status": "ok", "service": "gida-content-server", "version": "0.3.0"}


@app.get("/api/v1/blacklist")
async def get_blacklist():
    """Aktif kara liste kurallarını döndür."""
    return {"rules": [{"pattern": k, "reason": v} for k, v in BLACKLIST_RULES.items()]}


@app.post("/api/v1/blacklist", status_code=201)
async def add_blacklist_rule(rule: BlacklistRuleRequest):
    """Yeni bir kara liste kuralı ekle veya güncelle."""
    key = rule.pattern.lower().strip()
    if not key:
        raise HTTPException(status_code=400, detail="Pattern boş olamaz")
    BLACKLIST_RULES[key] = rule.reason
    return {"status": "added", "pattern": key, "reason": rule.reason}


@app.delete("/api/v1/blacklist/{pattern}")
async def remove_blacklist_rule(pattern: str):
    """Kara listeden kural sil."""
    key = pattern.lower().strip()
    removed = BLACKLIST_RULES.pop(key, None)
    if removed is None:
        raise HTTPException(status_code=404, detail="Kural bulunamadı")
    return {"status": "removed", "pattern": key}


@app.post("/api/v1/content", response_model=ContentResponse, status_code=201)
async def receive_content(
    request: Request,
    session: AsyncSession = Depends(get_session),
):
    """Accessibility Service'ten gelen içeriği değerlendir, kaydet ve engel kararını döndür."""
    content_type = request.headers.get("content-type", "")
    uploaded_files = []

    if content_type.startswith("multipart/form-data"):
        form = await request.form()
        raw_payload = form.get("data") or form.get("payload")
        if not raw_payload:
            raise HTTPException(status_code=400, detail="Missing data field in multipart form")

        if isinstance(raw_payload, str):
            payload_dict = json.loads(raw_payload)
        else:
            payload_dict = raw_payload

        payload = ContentCreate(**payload_dict)

        for key, value in form.multi_items():
            if hasattr(value, "filename") and value.filename:
                uploaded_files.append(value)
    else:
        body = await request.json()
        payload = ContentCreate(**body)

    content_id = f"cnt_{uuid.uuid4().hex[:12]}"
    is_blocked, block_reason = evaluate_content(payload)

    record = CapturedContent(
        content_id=content_id,
        device_id=payload.device_id,
        url=payload.url,
        page_title=payload.page_title,
        visible_text=payload.visible_text,
        browser_package=payload.browser_package,
        event_type=payload.event_type,
        is_blocked=is_blocked,
        block_reason=block_reason,
        timestamp=payload.timestamp,
    )
    session.add(record)

    saved_images_count = 0
    for idx, upload_file in enumerate(uploaded_files):
        try:
            original_ext = Path(upload_file.filename).suffix or ".jpg"
            saved_filename = f"{content_id}_{idx}{original_ext}"
            file_path = STORAGE_DIR / saved_filename

            content_bytes = await upload_file.read()
            with open(file_path, "wb") as f:
                f.write(content_bytes)

            image_record = CapturedImage(
                content_id=content_id,
                file_name=saved_filename,
                file_path=str(file_path),
                file_size=len(content_bytes),
            )
            session.add(image_record)
            saved_images_count += 1
        except Exception as e:
            print(f"Error saving image {upload_file.filename}: {e}")

    await session.commit()

    return ContentResponse(
        content_id=content_id,
        status="blocked" if is_blocked else "received",
        saved_images_count=saved_images_count,
        is_blocked=is_blocked,
        block_reason=block_reason,
        blocked_url=payload.url if is_blocked else "",
        timestamp=datetime.utcnow(),
    )


@app.get("/api/v1/images/{file_name}")
async def get_image(file_name: str):
    """Kaydedilen görseli indir/görüntüle."""
    safe_name = os.path.basename(file_name)
    file_path = STORAGE_DIR / safe_name
    if not file_path.exists():
        raise HTTPException(status_code=404, detail="Image not found")
    return FileResponse(file_path)


@app.get("/api/v1/logs", response_model=ContentLogResponse)
async def get_logs(
    device_id: str = Query(None, description="Cihaz ID'sine göre filtrele"),
    limit: int = Query(50, ge=1, le=500, description="Maksimum kayıt sayısı"),
    session: AsyncSession = Depends(get_session),
):
    """Kaydedilen içerikleri ve ilişkili görselleri listele."""
    count_query = select(func.count(CapturedContent.id))
    if device_id:
        count_query = count_query.where(CapturedContent.device_id == device_id)
    total_result = await session.execute(count_query)
    total = total_result.scalar() or 0

    query = select(CapturedContent).order_by(CapturedContent.timestamp.desc()).limit(limit)
    if device_id:
        query = query.where(CapturedContent.device_id == device_id)
    result = await session.execute(query)
    records = result.scalars().all()

    items = []
    for r in records:
        image_infos = [
            ImageInfo(
                id=img.id,
                file_name=img.file_name,
                file_size=img.file_size,
                url=f"/api/v1/images/{img.file_name}",
            )
            for img in (r.images or [])
        ]

        items.append(
            ContentLogItem(
                content_id=r.content_id,
                url=r.url,
                page_title=r.page_title,
                timestamp=r.timestamp,
                browser_package=r.browser_package,
                is_blocked=bool(r.is_blocked),
                block_reason=r.block_reason or "",
                images=image_infos,
            )
        )

    return ContentLogResponse(total=total, items=items)
