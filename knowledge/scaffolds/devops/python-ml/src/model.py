"""Neural network model definitions."""

import torch
import torch.nn as nn
import torch.nn.functional as F


class SimpleNet(nn.Module):
    """A simple feedforward neural network for classification.

    Args:
        input_dim: Number of input features.
        hidden_dim: Number of hidden units per layer.
        output_dim: Number of output classes.
        dropout: Dropout rate between layers.
    """

    def __init__(
        self,
        input_dim: int = 784,
        hidden_dim: int = 256,
        output_dim: int = 10,
        dropout: float = 0.2,
    ):
        super().__init__()
        self.fc1 = nn.Linear(input_dim, hidden_dim)
        self.bn1 = nn.BatchNorm1d(hidden_dim)
        self.fc2 = nn.Linear(hidden_dim, hidden_dim // 2)
        self.bn2 = nn.BatchNorm1d(hidden_dim // 2)
        self.fc3 = nn.Linear(hidden_dim // 2, output_dim)
        self.dropout = nn.Dropout(dropout)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Forward pass.

        Args:
            x: Input tensor of shape (batch_size, input_dim).

        Returns:
            Output logits of shape (batch_size, output_dim).
        """
        x = x.view(x.size(0), -1)
        x = self.dropout(F.relu(self.bn1(self.fc1(x))))
        x = self.dropout(F.relu(self.bn2(self.fc2(x))))
        x = self.fc3(x)
        return x


class ConvNet(nn.Module):
    """A convolutional neural network for image classification.

    Args:
        in_channels: Number of input channels.
        num_classes: Number of output classes.
        dropout: Dropout rate.
    """

    def __init__(
        self,
        in_channels: int = 1,
        num_classes: int = 10,
        dropout: float = 0.25,
    ):
        super().__init__()
        self.features = nn.Sequential(
            nn.Conv2d(in_channels, 32, kernel_size=3, padding=1),
            nn.BatchNorm2d(32),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
            nn.Conv2d(32, 64, kernel_size=3, padding=1),
            nn.BatchNorm2d(64),
            nn.ReLU(inplace=True),
            nn.MaxPool2d(2),
            nn.Dropout2d(dropout),
        )
        self.classifier = nn.Sequential(
            nn.Flatten(),
            nn.Linear(64 * 7 * 7, 128),
            nn.ReLU(inplace=True),
            nn.Dropout(dropout),
            nn.Linear(128, num_classes),
        )

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        """Forward pass.

        Args:
            x: Input tensor of shape (batch_size, in_channels, height, width).

        Returns:
            Output logits of shape (batch_size, num_classes).
        """
        x = self.features(x)
        x = self.classifier(x)
        return x
