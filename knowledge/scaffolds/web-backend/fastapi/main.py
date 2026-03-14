import uvicorn
from fastapi import FastAPI
from app.routers import items

app = FastAPI(
    title="My API",
    description="FastAPI application",
    version="1.0.0",
)

app.include_router(items.router, prefix="/api/items", tags=["items"])


@app.get("/")
async def root():
    return {"message": "Hello from FastAPI"}


@app.get("/health")
async def health():
    return {"status": "ok"}


if __name__ == "__main__":
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=True)
