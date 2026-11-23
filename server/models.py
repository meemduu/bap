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


class ImageInfo(BaseModel):
    """Kaydedilen görsel bilgisi."""

    id: int
    file_name: str
    file_size: int
    url: str


class ContentResponse(BaseModel):
    """POST /api/v1/content başarılı yanıt modeli."""

    content_id: str
    status: str = "received"
    saved_images_count: int = 0
    is_blocked: bool = False
    block_reason: str = ""
    blocked_url: str = ""
    timestamp: datetime


class ContentLogItem(BaseModel):
    """GET /api/v1/logs yanıtındaki tek bir kayıt."""

    content_id: str
    url: str
    page_title: str
    timestamp: datetime
    browser_package: str
    is_blocked: bool = False
    block_reason: str = ""
    images: list[ImageInfo] = []


class ContentLogResponse(BaseModel):
    """GET /api/v1/logs yanıt modeli."""

    total: int
    items: list[ContentLogItem]


class BlacklistRuleRequest(BaseModel):
    """Dinamik kara liste kuralı ekleme isteği."""

    pattern: str = Field(..., description="Engellenecek domain veya anahtar kelime")
    reason: str = Field("Zararlı içerik tespit edildi", description="Engelleme sebebi")
