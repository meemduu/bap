"""GiDA Server — Pydantic veri modelleri."""

from datetime import datetime
from typing import Optional

from pydantic import BaseModel, Field


class ContentCreate(BaseModel):
    """POST /api/v1/content isteği için gelen veri modeli."""

    device_id: str = Field(..., description="Android cihaz UUID'si")
    url: str = Field(..., description="Ziyaret edilen URL")
    page_title: str = Field("", description="Sayfa başlığı")
    visible_text: str = Field("", description="Ekranda görünen metin içeriği")
    browser_package: str = Field("", description="Browser paket adı (ör: com.android.chrome)")
    timestamp: datetime = Field(default_factory=datetime.utcnow, description="İçerik yakalama zamanı")
    event_type: str = Field("PAGE_VISIT", description="Olay türü")


class ContentResponse(BaseModel):
    """POST /api/v1/content başarılı yanıt modeli."""

    content_id: str
    status: str = "received"
    timestamp: datetime


class ContentLogItem(BaseModel):
    """GET /api/v1/logs yanıtındaki tek bir kayıt."""

    content_id: str
    url: str
    page_title: str
    timestamp: datetime
    browser_package: str


class ContentLogResponse(BaseModel):
    """GET /api/v1/logs yanıt modeli."""

    total: int
    items: list[ContentLogItem]
