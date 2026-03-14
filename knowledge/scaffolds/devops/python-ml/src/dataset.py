"""Dataset loading and preprocessing utilities."""

from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, Dataset, random_split


class TabularDataset(Dataset):
    """A dataset for tabular data stored as NumPy arrays or CSV files.

    Args:
        features: Feature array of shape (num_samples, num_features).
        targets: Target array of shape (num_samples,).
        transform: Optional callable to transform features.
    """

    def __init__(
        self,
        features: np.ndarray,
        targets: np.ndarray,
        transform=None,
    ):
        self.features = torch.FloatTensor(features)
        self.targets = torch.LongTensor(targets)
        self.transform = transform

    def __len__(self) -> int:
        return len(self.targets)

    def __getitem__(self, idx: int) -> tuple[torch.Tensor, torch.Tensor]:
        x = self.features[idx]
        y = self.targets[idx]
        if self.transform:
            x = self.transform(x)
        return x, y


def load_csv_dataset(
    filepath: str | Path,
    target_column: str = "target",
    test_size: float = 0.2,
) -> tuple[TabularDataset, TabularDataset]:
    """Load a CSV file into train and test TabularDatasets.

    Args:
        filepath: Path to the CSV file.
        target_column: Name of the target column.
        test_size: Fraction of data to use for testing.

    Returns:
        Tuple of (train_dataset, test_dataset).
    """
    import pandas as pd

    df = pd.read_csv(filepath)
    targets = df[target_column].values
    features = df.drop(columns=[target_column]).values

    full_dataset = TabularDataset(features, targets)
    test_len = int(len(full_dataset) * test_size)
    train_len = len(full_dataset) - test_len

    train_dataset, test_dataset = random_split(
        full_dataset,
        [train_len, test_len],
        generator=torch.Generator().manual_seed(42),
    )
    return train_dataset, test_dataset


def create_dataloaders(
    train_dataset: Dataset,
    test_dataset: Dataset,
    batch_size: int = 64,
    num_workers: int = 0,
) -> tuple[DataLoader, DataLoader]:
    """Create DataLoaders for training and testing.

    Args:
        train_dataset: Training dataset.
        test_dataset: Test dataset.
        batch_size: Batch size.
        num_workers: Number of data loading workers.

    Returns:
        Tuple of (train_loader, test_loader).
    """
    train_loader = DataLoader(
        train_dataset,
        batch_size=batch_size,
        shuffle=True,
        num_workers=num_workers,
        pin_memory=True,
    )
    test_loader = DataLoader(
        test_dataset,
        batch_size=batch_size,
        shuffle=False,
        num_workers=num_workers,
        pin_memory=True,
    )
    return train_loader, test_loader
