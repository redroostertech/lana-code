from pydantic import BaseModel, Field


class ItemBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=100, examples=["Widget"])
    description: str | None = Field(default=None, max_length=500)
    price: float = Field(..., gt=0, examples=[9.99])


class ItemCreate(ItemBase):
    pass


class Item(ItemBase):
    id: int

    model_config = {"from_attributes": True}


class Message(BaseModel):
    message: str
