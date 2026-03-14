"""Model evaluation and metrics computation."""

from pathlib import Path

import matplotlib.pyplot as plt
import numpy as np
import torch
import torch.nn as nn
import yaml
from sklearn.metrics import (
    accuracy_score,
    classification_report,
    confusion_matrix,
    f1_score,
    precision_score,
    recall_score,
)
from torch.utils.data import DataLoader
from tqdm import tqdm

from .model import SimpleNet


def predict(
    model: nn.Module,
    dataloader: DataLoader,
    device: torch.device,
) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Generate predictions for a dataset.

    Args:
        model: Trained model.
        dataloader: Data loader.
        device: Device to run on.

    Returns:
        Tuple of (all_targets, all_predictions, all_probabilities).
    """
    model.eval()
    all_targets = []
    all_preds = []
    all_probs = []

    with torch.no_grad():
        for features, targets in tqdm(dataloader, desc="Predicting", leave=False):
            features = features.to(device)
            outputs = model(features)
            probs = torch.softmax(outputs, dim=1)
            _, predicted = outputs.max(1)

            all_targets.extend(targets.cpu().numpy())
            all_preds.extend(predicted.cpu().numpy())
            all_probs.extend(probs.cpu().numpy())

    return (
        np.array(all_targets),
        np.array(all_preds),
        np.array(all_probs),
    )


def compute_metrics(targets: np.ndarray, predictions: np.ndarray) -> dict[str, float]:
    """Compute classification metrics.

    Args:
        targets: Ground truth labels.
        predictions: Model predictions.

    Returns:
        Dictionary of metric names to values.
    """
    return {
        "accuracy": accuracy_score(targets, predictions),
        "precision_macro": precision_score(targets, predictions, average="macro", zero_division=0),
        "recall_macro": recall_score(targets, predictions, average="macro", zero_division=0),
        "f1_macro": f1_score(targets, predictions, average="macro", zero_division=0),
        "f1_weighted": f1_score(targets, predictions, average="weighted", zero_division=0),
    }


def plot_confusion_matrix(
    targets: np.ndarray,
    predictions: np.ndarray,
    class_names: list[str] | None = None,
    output_path: str | Path = "confusion_matrix.png",
):
    """Plot and save a confusion matrix.

    Args:
        targets: Ground truth labels.
        predictions: Model predictions.
        class_names: Optional list of class names.
        output_path: Path to save the plot.
    """
    cm = confusion_matrix(targets, predictions)
    fig, ax = plt.subplots(figsize=(8, 6))
    im = ax.imshow(cm, interpolation="nearest", cmap=plt.cm.Blues)
    ax.set_title("Confusion Matrix")
    fig.colorbar(im)

    if class_names:
        tick_marks = np.arange(len(class_names))
        ax.set_xticks(tick_marks)
        ax.set_xticklabels(class_names, rotation=45, ha="right")
        ax.set_yticks(tick_marks)
        ax.set_yticklabels(class_names)

    ax.set_xlabel("Predicted")
    ax.set_ylabel("True")
    plt.tight_layout()
    plt.savefig(output_path, dpi=150)
    plt.close()
    print(f"Confusion matrix saved to {output_path}")


def main():
    """Main evaluation entry point."""
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

    # Load model
    model = SimpleNet(
        input_dim=config["model"]["input_dim"],
        hidden_dim=config["model"]["hidden_dim"],
        output_dim=config["model"]["output_dim"],
        dropout=config["model"]["dropout"],
    ).to(device)

    model_path = Path(config["output_dir"]) / "best_model.pt"
    if model_path.exists():
        checkpoint = torch.load(model_path, map_location=device, weights_only=True)
        if isinstance(checkpoint, dict) and "model_state_dict" in checkpoint:
            model.load_state_dict(checkpoint["model_state_dict"])
        else:
            model.load_state_dict(checkpoint)
        print(f"Loaded model from {model_path}")
    else:
        print(f"No model found at {model_path}, using random weights")

    # NOTE: Replace with actual test dataloader from dataset.py
    # targets, predictions, probabilities = predict(model, test_loader, device)
    # metrics = compute_metrics(targets, predictions)
    #
    # print("\nEvaluation Results:")
    # for name, value in metrics.items():
    #     print(f"  {name}: {value:.4f}")
    #
    # print("\nClassification Report:")
    # print(classification_report(targets, predictions))
    #
    # plot_confusion_matrix(targets, predictions, output_path=Path(config["output_dir"]) / "confusion_matrix.png")

    print("Evaluation script ready. Connect your data pipeline to run.")


if __name__ == "__main__":
    main()
