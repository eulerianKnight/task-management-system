from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session
from pydantic import BaseModel
from typing import List, Optional

from app.database import get_db
from app.models import Project, User
from app.routers.auth import get_current_user

router = APIRouter()


class ProjectCreate(BaseModel):
    name: str
    description: Optional[str] = None


class ProjectResponse(BaseModel):
    id: int
    name: str
    description: Optional[str]
    is_active: bool
    created_by_id: int
    created_at: str
    task_count: int = 0
    member_count: int = 0


@router.post("/", response_model=ProjectResponse)
def create_project(
        project: ProjectCreate,
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    db_project = Project(
        name=project.name,
        description=project.description,
        created_by_id=current_user.id
    )

    # Add creator as a member
    db_project.members.append(current_user)

    db.add(db_project)
    db.commit()
    db.refresh(db_project)

    return ProjectResponse(
        id=db_project.id,
        name=db_project.name,
        description=db_project.description,
        is_active=db_project.is_active,
        created_by_id=db_project.created_by_id,
        created_at=db_project.created_at.isoformat(),
        task_count=0,
        member_count=1
    )


@router.get("/", response_model=List[ProjectResponse])
def get_projects(
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    # Get projects where user is member or creator
    projects = db.query(Project).filter(
        (Project.members.contains(current_user)) | (Project.created_by_id == current_user.id)
    ).all()

    result = []
    for project in projects:
        task_count = len(project.tasks)
        member_count = len(project.members)

        result.append(ProjectResponse(
            id=project.id,
            name=project.name,
            description=project.description,
            is_active=project.is_active,
            created_by_id=project.created_by_id,
            created_at=project.created_at.isoformat(),
            task_count=task_count,
            member_count=member_count
        ))

    return result