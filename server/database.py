"""GiDA Server — SQLAlchemy veritabanı katmanı (async SQLite)."""

from datetime import datetime

from sqlalchemy import Boolean, Column, DateTime, ForeignKey, Integer, String, Text, text
from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase, relationship

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
    is_blocked = Column(Boolean, default=False)
    block_reason = Column(Text, default="")
    timestamp = Column(DateTime, default=datetime.utcnow)
    created_at = Column(DateTime, default=datetime.utcnow)

    images = relationship("CapturedImage", back_populates="content", cascade="all, delete-orphan", lazy="selectin")


class CapturedImage(Base):
    """Yakalanan içeriğe ait kırpılmış görseller."""

    __tablename__ = "captured_images"

    id = Column(Integer, primary_key=True, autoincrement=True)
    content_id = Column(String(50), ForeignKey("captured_contents.content_id"), nullable=False, index=True)
    file_name = Column(String(255), nullable=False)
    file_path = Column(Text, nullable=False)
    file_size = Column(Integer, default=0)
    created_at = Column(DateTime, default=datetime.utcnow)

    content = relationship("CapturedContent", back_populates="images")


async def init_db():
    """Veritabanı tablolarını oluştur ve eksik sütunları ekle."""
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
        for alter_sql in [
            "ALTER TABLE captured_contents ADD COLUMN is_blocked BOOLEAN DEFAULT 0",
            "ALTER TABLE captured_contents ADD COLUMN block_reason TEXT DEFAULT ''",
        ]:
            try:
                await conn.execute(text(alter_sql))
            except Exception:
                pass


async def get_session() -> AsyncSession:
    """Yeni bir veritabanı oturumu döndür."""
    async with async_session() as session:
        yield session
