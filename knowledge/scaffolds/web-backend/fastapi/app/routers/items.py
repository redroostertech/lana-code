from fastapi import APIRouter, HTTPException
from app.models import Item, ItemCreate, Message

router = APIRouter()

# In-memory store for demonstration
_items: dict[int, Item] = {}
_next_id: int = 1


@router.get("/", response_model=list[Item])
async def list_items():
    """List all items."""
    return list(_items.values())


@router.get("/{item_id}", response_model=Item)
async def get_item(item_id: int):
    """Get a single item by ID."""
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="Item not found")
    return _items[item_id]


@router.post("/", response_model=Item, status_code=201)
async def create_item(item: ItemCreate):
    """Create a new item."""
    global _next_id
    new_item = Item(id=_next_id, **item.model_dump())
    _items[_next_id] = new_item
    _next_id += 1
    return new_item


@router.put("/{item_id}", response_model=Item)
async def update_item(item_id: int, item: ItemCreate):
    """Update an existing item."""
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="Item not found")
    updated = Item(id=item_id, **item.model_dump())
    _items[item_id] = updated
    return updated


@router.delete("/{item_id}", response_model=Message)
async def delete_item(item_id: int):
    """Delete an item."""
    if item_id not in _items:
        raise HTTPException(status_code=404, detail="Item not found")
    del _items[item_id]
    return Message(message=f"Item {item_id} deleted")
