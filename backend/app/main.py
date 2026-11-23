from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware

from app.api.routes.health import router as health_router
from app.api.routes.v1 import router as api_router
from app.core.config import settings
from app.services.llm_keep_warm import keep_receipt_llm_warm


def create_app() -> FastAPI:
    app = FastAPI(
        title=settings.app_name,
        debug=settings.debug,
        docs_url="/docs" if settings.enable_api_docs else None,
        redoc_url="/redoc" if settings.enable_api_docs else None,
        openapi_url="/openapi.json" if settings.enable_api_docs else None,
    )

    app.add_middleware(
        CORSMiddleware,
        allow_origins=settings.cors_origins,
        allow_credentials=False,
        allow_methods=["*"],
        allow_headers=["*"],
    )

    app.include_router(health_router)
    app.include_router(api_router)

    @app.on_event("startup")
    async def _start_llm_keep_warm() -> None:
        import asyncio

        app.state.receipt_llm_keep_warm_task = asyncio.create_task(
            keep_receipt_llm_warm()
        )

    @app.on_event("shutdown")
    async def _stop_llm_keep_warm() -> None:
        task = getattr(app.state, "receipt_llm_keep_warm_task", None)
        if task is not None:
            task.cancel()

    return app


app = create_app()
