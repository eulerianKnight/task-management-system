from fastapi import FastAPI, Depends, HTTPException, status
from fastapi.middleware.cors import CORSMiddleware
from fastapi.security import HTTPBearer
from sqlalchemy.orm import Session
import redis
import os
from contextlib import asynccontextmanager

from app.database import get_db, engine
from app.models import Base
from app.routers import auth, tasks, users, projects
from app.core.config import settings
from app.core.redis_client import get_redis_client

# Create tables
Base.metadata.create_all(bind=engine)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # Startup
    print("Starting Task Management API...")

    # Test database connection
    try:
        with get_db().__next__() as db:
            db.execute("SELECT 1")
        print("PostgreSQL connection successful")
    except Exception as e:
        print(f"PostgreSQL connection failed: {e}")

    # Test Redis connection
    try:
        redis_client = get_redis_client()
        redis_client.ping()
        print("Redis connection successful")
    except Exception as e:
        print(f"Redis connection failed: {e}")

    yield

    # Shutdown
    print("Shutting down Task Management API...")


app = FastAPI(
    title="Task Management System",
    description="A comprehensive task management system with real-time features",
    version="1.0.0",
    lifespan=lifespan
)

# CORS middleware
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.ALLOWED_HOSTS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Include routers
app.include_router(auth.router, prefix="/api/v1/auth", tags=["Authentication"])
app.include_router(users.router, prefix="/api/v1/users", tags=["Users"])
app.include_router(projects.router, prefix="/api/v1/projects", tags=["Projects"])
app.include_router(tasks.router, prefix="/api/v1/tasks", tags=["Tasks"])


@app.get("/")
async def root():
    return {"message": "Task Management System API", "version": "1.0.0"}


@app.get("/health")
async def health_check(db: Session = Depends(get_db)):
    """Health check endpoint for Kubernetes readiness/liveness probes"""
    try:
        # Check database
        db.execute("SELECT 1")

        # Check Redis
        redis_client = get_redis_client()
        redis_client.ping()

        return {
            "status": "healthy",
            "database": "connected",
            "redis": "connected",
            "version": "1.0.0"
        }
    except Exception as e:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=f"Service unhealthy: {str(e)}"
        )

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "main:app",
        host="0.0.0.0",
        port=int(os.getenv("PORT", 8000)),
        reload=os.getenv("ENVIRONMENT") == "development"
    )