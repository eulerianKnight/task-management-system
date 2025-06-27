from fastapi import APIRouter, Depends
from app.routers.auth import get_current_user
from app.models import User

router = APIRouter()


@router.get("/profile")
def get_user_profile(current_user: User = Depends(get_current_user)):
    return {
        "id": current_user.id,
        "email": current_user.email,
        "username": current_user.username,
        "full_name": current_user.full_name,
        "role": current_user.role,
        "created_at": current_user.created_at
    }