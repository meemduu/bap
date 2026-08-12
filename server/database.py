"""GiDA Server — SQLAlchemy veritabanı katmanı (async SQLite)."""

from datetime import datetime

from sqlalchemy import Column, DateTime, Integer, String, Text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

DATABASE_URL = "sqlite+aiosqlite:///./gida.db"

engine = create_async_engine(DATABASE_URL, echo=False)
async_session = async_sessionmaker(engine, class_=AsyncSession, expire_on_commit=False)


class Base(DeclarativeBase):
    pass


class CapturedContent(Base):
    """Accessibility Service'ten gelen yakalanan içerik kaydı."""

    __tablename__ = "captured_contents"

    id = Column(Integer, primary_key=True, autoincrement=True)
    content_id = Column(String(50), unique=True, nullable=False, index=True)
    device_id = Column(String(100), nullable=False, index=True)
    url = Column(Text, nullable=False)
    page_title = Column(Text, default="")
    visible_text = Column(Text, default="")
    browser_package = Column(String(100), default="")
    event_type = Column(String(50), default="PAGE_VISIT")
    timestamp = Column(DateTime, default=datetime.utcnow)
    created_at = Column(DateTime, default=datetime.utcnow)


async def init_db():
    """Veritabanı tablolarını oluştur."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_session() -> AsyncSession:
    """Yeni bir veritabanı oturumu döndür."""
    async with async_session() as session:
        yield session
