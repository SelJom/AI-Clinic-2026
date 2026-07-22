from __future__ import annotations

import math
from dataclasses import dataclass


@dataclass
class EWMAAnomalyDetector:
    """Streaming, constant-memory anomaly scorer for a single continuous signal
    (e.g. live heart rate). Mirrors what the wearable-TinyML literature runs
    on-device: track a moving mean/variance and flag reconstruction-style
    deviation, without needing to buffer history or run a trained model.

    alpha: smoothing factor for the running mean (higher = adapts faster).
    """

    alpha: float = 0.05
    _mean: float | None = None
    _var: float = 0.0
    warmup_samples: int = 30
    _n: int = 0

    def update(self, value: float) -> float:
        """Feed one new sample, return its anomaly score (~z-score-like units)."""
        self._n += 1
        if self._mean is None:
            self._mean = value
            return 0.0

        deviation = value - self._mean
        self._mean += self.alpha * deviation
        self._var = (1 - self.alpha) * (self._var + self.alpha * deviation**2)

        if self._n < self.warmup_samples:
            return 0.0

        std = math.sqrt(self._var) or 1e-6
        return deviation / std

    @property
    def is_warmed_up(self) -> bool:
        return self._n >= self.warmup_samples

    @property
    def baseline(self) -> float | None:
        return self._mean
