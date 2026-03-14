"""Training loop and utilities."""

import time
from pathlib import Path

import torch
import torch.nn as nn
import yaml
from torch.optim import Adam
from torch.optim.lr_scheduler import ReduceLROnPlateau
from torch.utils.data import DataLoader
from tqdm import tqdm

from .model import SimpleNet


def train_one_epoch(
    model: nn.Module,
    dataloader: DataLoader,
    criterion: nn.Module,
    optimizer: torch.optim.Optimizer,
    device: torch.device,
) -> dict[str, float]:
    """Train the model for one epoch.

    Args:
        model: The neural network model.
        dataloader: Training data loader.
        criterion: Loss function.
        optimizer: Optimizer.
        device: Device to train on.

    Returns:
        Dictionary with 'loss' and 'accuracy' for the epoch.
    """
    model.train()
    total_loss = 0.0
    correct = 0
    total = 0

    for features, targets in tqdm(dataloader, desc="Training", leave=False):
        features, targets = features.to(device), targets.to(device)

        optimizer.zero_grad()
        outputs = model(features)
        loss = criterion(outputs, targets)
        loss.backward()
        optimizer.step()

        total_loss += loss.item() * features.size(0)
        _, predicted = outputs.max(1)
        total += targets.size(0)
        correct += predicted.eq(targets).sum().item()

    return {
        "loss": total_loss / total,
        "accuracy": correct / total,
    }


def validate(
    model: nn.Module,
    dataloader: DataLoader,
    criterion: nn.Module,
    device: torch.device,
) -> dict[str, float]:
    """Validate the model.

    Args:
        model: The neural network model.
        dataloader: Validation data loader.
        criterion: Loss function.
        device: Device to validate on.

    Returns:
        Dictionary with 'loss' and 'accuracy'.
    """
    model.eval()
    total_loss = 0.0
    correct = 0
    total = 0

    with torch.no_grad():
        for features, targets in tqdm(dataloader, desc="Validation", leave=False):
            features, targets = features.to(device), targets.to(device)
            outputs = model(features)
            loss = criterion(outputs, targets)

            total_loss += loss.item() * features.size(0)
            _, predicted = outputs.max(1)
            total += targets.size(0)
            correct += predicted.eq(targets).sum().item()

    return {
        "loss": total_loss / total,
        "accuracy": correct / total,
    }


def main():
    """Main training entry point."""
    # Load config
    config_path = Path("configs/default.yaml")
    with open(config_path) as f:
        config = yaml.safe_load(f)

    # Device
    if torch.backends.mps.is_available():
        device = torch.device("mps")
    elif torch.cuda.is_available():
        device = torch.device("cuda")
    else:
        device = torch.device("cpu")
    print(f"Using device: {device}")

    # Seed
    torch.manual_seed(config["seed"])

    # Model
    model = SimpleNet(
        input_dim=config["model"]["input_dim"],
        hidden_dim=config["model"]["hidden_dim"],
        output_dim=config["model"]["output_dim"],
        dropout=config["model"]["dropout"],
    ).to(device)

    print(f"Model parameters: {sum(p.numel() for p in model.parameters()):,}")

    # Loss and optimizer
    criterion = nn.CrossEntropyLoss()
    optimizer = Adam(
        model.parameters(),
        lr=config["training"]["learning_rate"],
        weight_decay=config["training"]["weight_decay"],
    )
    scheduler = ReduceLROnPlateau(
        optimizer,
        mode="min",
        factor=0.5,
        patience=config["training"]["scheduler_patience"],
    )

    # Training loop
    output_dir = Path(config["output_dir"])
    output_dir.mkdir(parents=True, exist_ok=True)

    best_val_loss = float("inf")

    print(f"Starting training for {config['training']['epochs']} epochs...")
    start_time = time.time()

    for epoch in range(1, config["training"]["epochs"] + 1):
        # NOTE: Replace these with real dataloaders from dataset.py
        # train_metrics = train_one_epoch(model, train_loader, criterion, optimizer, device)
        # val_metrics = validate(model, val_loader, criterion, device)

        print(f"Epoch {epoch}/{config['training']['epochs']}")

        # Placeholder: in a real project, use actual data
        # scheduler.step(val_metrics["loss"])

        # Save best model
        # if val_metrics["loss"] < best_val_loss:
        #     best_val_loss = val_metrics["loss"]
        #     torch.save({
        #         "epoch": epoch,
        #         "model_state_dict": model.state_dict(),
        #         "optimizer_state_dict": optimizer.state_dict(),
        #         "val_loss": best_val_loss,
        #     }, output_dir / "best_model.pt")

    elapsed = time.time() - start_time
    print(f"Training complete in {elapsed:.1f}s")

    # Save final model
    torch.save(model.state_dict(), output_dir / "final_model.pt")
    print(f"Model saved to {output_dir / 'final_model.pt'}")


if __name__ == "__main__":
    main()
