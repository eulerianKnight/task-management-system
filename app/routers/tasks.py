from fastapi import APIRouter, Depends, HTTPException, status, Query
from sqlalchemy.orm import Session, joinedload
from pydantic import BaseModel
from typing import List, Optional
from datetime import datetime

from app.database import get_db
from app.models import Task, User, Project, TaskStatus, TaskPriority
from app.routers.auth import get_current_user
from app.core.redis_client import get_redis_client

router = APIRouter()


class TaskCreate(BaseModel):
    title: str
    description: Optional[str] = None
    project_id: int
    assignee_id: Optional[int] = None
    priority: TaskPriority = TaskPriority.MEDIUM
    due_date: Optional[datetime] = None
    parent_task_id: Optional[int] = None


class TaskUpdate(BaseModel):
    title: Optional[str] = None
    description: Optional[str] = None
    status: Optional[TaskStatus] = None
    priority: Optional[TaskPriority] = None
    assignee_id: Optional[int] = None
    due_date: Optional[datetime] = None


class TaskResponse(BaseModel):
    id: int
    title: str
    description: Optional[str]
    status: TaskStatus
    priority: TaskPriority
    project_id: int
    assignee_id: Optional[int]
    parent_task_id: Optional[int]
    created_at: datetime
    updated_at: Optional[datetime]
    due_date: Optional[datetime]
    completed_at: Optional[datetime]

    # Related data
    project_name: Optional[str] = None
    assignee_name: Optional[str] = None
    subtask_count: int = 0

    class Config:
        from_attributes = True


@router.post("/", response_model=TaskResponse)
def create_task(
        task: TaskCreate,
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    # Verify project exists and user has access
    project = db.query(Project).filter(Project.id == task.project_id).first()
    if not project:
        raise HTTPException(status_code=404, detail="Project not found")

    # Check if user is member of the project
    if current_user not in project.members and project.created_by != current_user:
        raise HTTPException(status_code=403, detail="Not authorized to create tasks in this project")

    # Verify assignee exists and is project member
    if task.assignee_id:
        assignee = db.query(User).filter(User.id == task.assignee_id).first()
        if not assignee:
            raise HTTPException(status_code=404, detail="Assignee not found")
        if assignee not in project.members:
            raise HTTPException(status_code=400, detail="Assignee is not a member of this project")

    # Create task
    db_task = Task(**task.model_dump())
    db.add(db_task)
    db.commit()
    db.refresh(db_task)

    # Cache recent task activity in Redis
    redis_client = get_redis_client()
    try:
        redis_client.lpush(f"recent_tasks:{current_user.id}", db_task.id)
        redis_client.ltrim(f"recent_tasks:{current_user.id}", 0, 9)  # Keep last 10
        redis_client.expire(f"recent_tasks:{current_user.id}", 3600)  # 1 hour TTL
    except Exception as e:
        # Log error but don't fail the request
        print(f"Redis error: {e}")

    return _build_task_response(db_task, db)


@router.get("/", response_model=List[TaskResponse])
def get_tasks(
        project_id: Optional[int] = Query(None),
        status: Optional[TaskStatus] = Query(None),
        assignee_id: Optional[int] = Query(None),
        priority: Optional[TaskPriority] = Query(None),
        skip: int = Query(0, ge=0),
        limit: int = Query(100, ge=1, le=100),
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    # Build query
    query = db.query(Task).options(
        joinedload(Task.project),
        joinedload(Task.assignee)
    )

    # Filter by project access
    if project_id:
        project = db.query(Project).filter(Project.id == project_id).first()
        if not project or (current_user not in project.members and project.created_by != current_user):
            raise HTTPException(status_code=403, detail="Not authorized to view tasks in this project")
        query = query.filter(Task.project_id == project_id)
    else:
        # Only show tasks from projects user has access to
        accessible_projects = db.query(Project).filter(
            (Project.members.contains(current_user)) | (Project.created_by == current_user)
        ).all()
        project_ids = [p.id for p in accessible_projects]
        query = query.filter(Task.project_id.in_(project_ids))

    # Apply filters
    if status:
        query = query.filter(Task.status == status)
    if assignee_id:
        query = query.filter(Task.assignee_id == assignee_id)
    if priority:
        query = query.filter(Task.priority == priority)

    # Apply pagination
    tasks = query.offset(skip).limit(limit).all()

    return [_build_task_response(task, db) for task in tasks]


@router.get("/{task_id}", response_model=TaskResponse)
def get_task(
        task_id: int,
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    task = db.query(Task).options(
        joinedload(Task.project),
        joinedload(Task.assignee)
    ).filter(Task.id == task_id).first()

    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    # Check access
    if (current_user not in task.project.members and
            task.project.created_by != current_user):
        raise HTTPException(status_code=403, detail="Not authorized to view this task")

    return _build_task_response(task, db)


@router.put("/{task_id}", response_model=TaskResponse)
def update_task(
        task_id: int,
        task_update: TaskUpdate,
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    task = db.query(Task).filter(Task.id == task_id).first()

    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    # Check access
    if (current_user not in task.project.members and
            task.project.created_by != current_user):
        raise HTTPException(status_code=403, detail="Not authorized to update this task")

    # Update fields
    update_data = task_update.model_dump(exclude_unset=True)

    # Handle status change to completed
    if update_data.get("status") == TaskStatus.DONE and task.status != TaskStatus.DONE:
        update_data["completed_at"] = datetime.utcnow()
    elif update_data.get("status") != TaskStatus.DONE and task.status == TaskStatus.DONE:
        update_data["completed_at"] = None

    for field, value in update_data.items():
        setattr(task, field, value)

    task.updated_at = datetime.utcnow()
    db.commit()
    db.refresh(task)

    return _build_task_response(task, db)


@router.delete("/{task_id}")
def delete_task(
        task_id: int,
        current_user: User = Depends(get_current_user),
        db: Session = Depends(get_db)
):
    task = db.query(Task).filter(Task.id == task_id).first()

    if not task:
        raise HTTPException(status_code=404, detail="Task not found")

    # Check access (only project owner or task assignee can delete)
    if (task.project.created_by != current_user and task.assignee != current_user):
        raise HTTPException(status_code=403, detail="Not authorized to delete this task")

    db.delete(task)
    db.commit()

    return {"message": "Task deleted successfully"}


def _build_task_response(task: Task, db: Session) -> TaskResponse:
    """Helper function to build task response with related data"""
    subtask_count = db.query(Task).filter(Task.parent_task_id == task.id).count()

    return TaskResponse(
        id=task.id,
        title=task.title,
        description=task.description,
        status=task.status,
        priority=task.priority,
        project_id=task.project_id,
        assignee_id=task.assignee_id,
        parent_task_id=task.parent_task_id,
        created_at=task.created_at,
        updated_at=task.updated_at,
        due_date=task.due_date,
        completed_at=task.completed_at,
        project_name=task.project.name if task.project else None,
        assignee_name=task.assignee.full_name if task.assignee else None,
        subtask_count=subtask_count
    )