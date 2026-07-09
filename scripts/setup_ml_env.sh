#!/usr/bin/env bash
# setup_ml_env.sh — Create .venv-ml and install paper-faithful ML deps.
#
# Usage:
#   bash scripts/setup_ml_env.sh
#   bash scripts/setup_ml_env.sh --prefetch-weights
#
# The venv is created with --system-site-packages so torch/torchvision/numpy/
# Pillow/scikit-learn already present in the anaconda base env are visible
# inside it; only TensorFlow (plus its deps) is pip-installed on top.
#
# This script is idempotent: safe to re-run. It will NOT mutate the anaconda
# base env.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
VENV_DIR="${REPO_ROOT}/.venv-ml"
REQUIREMENTS="${REPO_ROOT}/requirements-ml.txt"

PREFETCH=0
for arg in "$@"; do
    case "${arg}" in
        --prefetch-weights) PREFETCH=1 ;;
        *) echo "[setup_ml_env] Unknown argument: ${arg}" >&2; exit 1 ;;
    esac
done

echo "[setup_ml_env] Repo root : ${REPO_ROOT}"
echo "[setup_ml_env] Venv      : ${VENV_DIR}"
echo "[setup_ml_env] Requires  : ${REQUIREMENTS}"

# ---------------------------------------------------------------------------
# 1. Create the venv if it does not already exist
# ---------------------------------------------------------------------------
if [ -d "${VENV_DIR}" ]; then
    echo "[setup_ml_env] Venv already exists — reusing it."
else
    echo "[setup_ml_env] Creating venv with --system-site-packages ..."
    python3 -m venv --system-site-packages "${VENV_DIR}"
    echo "[setup_ml_env] Venv created."
fi

VENV_PYTHON="${VENV_DIR}/bin/python"
VENV_PIP="${VENV_DIR}/bin/pip"

# ---------------------------------------------------------------------------
# 2. Upgrade pip inside the venv
# ---------------------------------------------------------------------------
echo "[setup_ml_env] Upgrading pip ..."
"${VENV_PIP}" install --upgrade pip

# ---------------------------------------------------------------------------
# 3. Install requirements
# ---------------------------------------------------------------------------
echo "[setup_ml_env] Installing requirements from ${REQUIREMENTS} ..."
"${VENV_PIP}" install -r "${REQUIREMENTS}"
echo "[setup_ml_env] Install complete."

# ---------------------------------------------------------------------------
# 3b. Fix h5py ABI mismatch
# ---------------------------------------------------------------------------
# The anaconda base ships h5py compiled against numpy 1.x (dtype size 96).
# With --system-site-packages and numpy 2.x visible in the venv, that binary
# is ABI-incompatible (dtype size 88). TensorFlow imports h5py at startup and
# crashes unless we install a numpy-2.x-compatible h5py INSIDE the venv.
# --ignore-installed forces pip to write a fresh wheel even though h5py is
# already visible through system-site-packages.
echo "[setup_ml_env] Force-installing numpy + h5py into venv (fixes ABI mismatch with base h5py) ..."
"${VENV_PIP}" install --ignore-installed "numpy>=2.0,<3.0" h5py
echo "[setup_ml_env] h5py fix complete."

# Show resolved TF version
TF_VERSION=$("${VENV_PYTHON}" -c "import warnings; warnings.filterwarnings('ignore'); import tensorflow; print(tensorflow.__version__)" 2>/dev/null || echo "NOT IMPORTABLE")
echo "[setup_ml_env] Resolved tensorflow version: ${TF_VERSION}"

# ---------------------------------------------------------------------------
# 4. (Optional) Prefetch model weights
# ---------------------------------------------------------------------------
if [ "${PREFETCH}" -eq 1 ]; then
    echo "[setup_ml_env] Prefetching pretrained weights (may download ~700 MB) ..."
    if "${VENV_PYTHON}" "${SCRIPT_DIR}/fetch_pretrained_weights.py"; then
        echo "[setup_ml_env] Weight prefetch complete."
    else
        echo "[setup_ml_env] WARN: Weight prefetch returned non-zero (non-fatal — pip install succeeded)."
    fi
fi

# ---------------------------------------------------------------------------
# 5. Usage hint
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "  Setup complete. To run the paper-faithful training pipeline:"
echo ""
echo "    source ${VENV_DIR}/bin/activate"
echo "    python scripts/train_hand_classifier.py --demo"
echo ""
echo "  You should see the banner:"
echo "    [PAPER-FAITHFUL] torch + tensorflow/keras both importable ..."
echo ""
echo "  To prefetch weights in advance (run once, ~700 MB):"
echo "    bash scripts/setup_ml_env.sh --prefetch-weights"
echo "================================================================"
