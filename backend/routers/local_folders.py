"""Paired folder management on the existing owner-scoped folder collection."""

from typing import Annotated

from fastapi import APIRouter, Depends, HTTPException, Path, Response
from google.api_core.exceptions import NotFound
from pydantic import BaseModel, Field

from database import folders
from models.folder import Folder
from utils.local_transport_auth import require_paired_owner

router = APIRouter(prefix='/v1/local/folders', tags=['local'])
FolderId = Annotated[str, Path(pattern=r'^[A-Za-z0-9_-]{1,128}$')]


class FolderName(BaseModel):
    name: str = Field(min_length=1, max_length=100)


def _name(body: FolderName) -> str:
    name = body.name.strip()
    if not name:
        raise HTTPException(400, 'local_folder_empty_name')
    return name


@router.get('', response_model=list[Folder])
def list_folders(response: Response, uid: str = Depends(require_paired_owner)):
    response.headers['Cache-Control'] = 'no-store'
    return folders.get_folders(uid)


@router.post('', response_model=Folder, status_code=201)
def create_folder(body: FolderName, uid: str = Depends(require_paired_owner)):
    name = _name(body)
    if sum(not folder.get('is_system') for folder in folders.get_folders(uid)) >= 50:
        raise HTTPException(409, 'local_folder_limit')
    return folders.create_folder(uid, name)


@router.patch('/{folder_id}', response_model=Folder)
def rename_folder(folder_id: FolderId, body: FolderName, uid: str = Depends(require_paired_owner)):
    try:
        folders.update_folder(uid, folder_id, {'name': _name(body)})
    except NotFound:
        raise HTTPException(404, 'local_folder_unavailable') from None
    folder = folders.get_folder(uid, folder_id)
    if folder is None:
        raise HTTPException(404, 'local_folder_unavailable')
    return folder
