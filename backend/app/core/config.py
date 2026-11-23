from functools import lru_cache
from pathlib import Path
from pydantic import model_validator

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    app_name: str = "TripScript Backend"
    app_env: str = "local"
    debug: bool = False
    enable_api_docs: bool = False
    enable_admin_api: bool = False
    enable_legacy_auth: bool = False
    cors_origins: list[str] = []
    admin_api_token: str = ""
    api_prefix: str = "/api"

    database_url: str = "sqlite:///./storage/tripscript.db"
    redis_url: str = "redis://redis:6379/0"

    jwt_secret_key: str = ""
    jwt_algorithm: str = "HS256"
    access_token_expire_minutes: int = 60 * 24 * 7

    storage_dir: str = "storage"

    receipt_ocr_provider: str = "tesseract_cli"
    receipt_ocr_langs: str = "eng+kor+jpn"
    receipt_ocr_psm: int = 6
    receipt_ocr_psm_modes: str = "4,6,11"
    receipt_ocr_service_url: str = "http://ocr:8010"
    receipt_easyocr_service_url: str = "http://easyocr:8011"
    receipt_image_preprocess_enabled: bool = True
    receipt_recognition_strategy: str = "cloud_gemini"
    receipt_vision_fallback_ocr_enabled: bool = True
    receipt_hybrid_vision_fallback_enabled: bool = False
    receipt_vision_flatten_enabled: bool = True
    receipt_vision_include_original_enabled: bool = False
    receipt_rule_first_enabled: bool = True
    receipt_llm_provider: str = "ollama_vision"
    receipt_llm_model: str = "qwen2.5vl:7b"
    receipt_text_llm_model: str = "qwen2.5:1.5b"
    receipt_text_llm_num_ctx: int = 4096
    receipt_text_llm_num_predict: int = 350
    receipt_text_llm_timeout_seconds: int = 22
    receipt_gemini_api_key: str = ""
    receipt_gemini_base_url: str = "https://generativelanguage.googleapis.com/v1beta"
    receipt_gemini_model: str = "gemini-2.5-flash"
    receipt_cloud_llm_timeout_seconds: int = 45
    receipt_cloud_llm_image_max_edge: int = 1600
    receipt_cloud_llm_image_jpeg_quality: int = 90
    receipt_cloud_llm_flatten_enabled: bool = True
    receipt_llm_base_url: str = "http://ollama:11434"
    receipt_llm_api_key: str = ""
    receipt_llm_pipeline: str = "fast"
    receipt_llm_keep_alive: str = "10m"
    receipt_llm_repair_enabled: bool = True
    receipt_recognition_timeout_seconds: int = 180
    receipt_llm_image_max_edge: int = 1600
    receipt_llm_image_jpeg_quality: int = 92
    receipt_llm_num_ctx: int = 8192
    receipt_llm_num_predict: int = 900
    receipt_qwen_safe_resize_enabled: bool = True
    receipt_qwen_safe_resize_edge: int = 1344
    receipt_llm_keep_warm_enabled: bool = True
    receipt_llm_keep_warm_interval_seconds: int = 900

    card_fee_research_enabled: bool = True
    card_fee_research_model: str = "qwen2.5:3b"
    card_fee_research_timeout_seconds: int = 90
    card_fee_research_max_sources: int = 4

    @property
    def sqlite_path(self) -> Path:
        prefix = "sqlite:///"
        if not self.database_url.startswith(prefix):
            raise ValueError("This backend currently supports SQLite DATABASE_URL only")
        return Path(self.database_url[len(prefix):])

    @model_validator(mode="after")
    def validate_security(self):
        if len(self.jwt_secret_key.strip()) < 32 or self.jwt_secret_key.startswith("change-me"):
            raise ValueError("Set JWT_SECRET_KEY to a random secret of at least 32 characters")
        if self.enable_admin_api and (len(self.admin_api_token.strip()) < 32 or self.admin_api_token.startswith("change-me")):
            raise ValueError("Set a random ADMIN_API_TOKEN of at least 32 characters")
        if self.app_env != "local" and self.enable_legacy_auth:
            raise ValueError("ENABLE_LEGACY_AUTH is only allowed with APP_ENV=local")
        return self

    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")


@lru_cache
def get_settings() -> Settings:
    return Settings()


settings = get_settings()
