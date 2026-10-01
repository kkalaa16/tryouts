#!/usr/bin/env bash
# Copy saakethramoju's public repos and Vinay25112001/eVTOLSizer into your own
# GitHub account as independent repositories (not GitHub forks), with full
# history: every branch and tag.
#
# Requirements: git, and the GitHub CLI (`gh`) logged in as the target account
# (`gh auth login`). Run from any empty working directory:
#
#   bash copy-repos-to-github.sh             # private copies (default)
#   VISIBILITY=public bash copy-repos-to-github.sh
#
# Licences: FullFlow, FullPlot and ThermoProp are GPL-3.0 and eVTOLSizer is
# Apache-2.0, so public copies of those are fine as long as the LICENSE/NOTICE
# files stay. The other 14 repos carry no licence, which means all rights are
# reserved by the author, so keep those private unless Saaketh agrees.
#
# To contribute changes back upstream later, open pull requests from a real
# GitHub fork. A copy made by this script has no fork link to the original.

set -euo pipefail

OWNER="${OWNER:-kkalaa16}"
VISIBILITY="${VISIBILITY:-private}"   # private | public
WORKDIR="${WORKDIR:-$(pwd)/repo-copies}"

REPOS=(
  saakethramoju/FullFlow
  saakethramoju/FullPlot
  saakethramoju/ThermoProp
  saakethramoju/Raptor
  saakethramoju/saakethramoju.github.io
  saakethramoju/saakethramoju
  saakethramoju/rocketflow
  saakethramoju/FluidWrapper
  saakethramoju/Throttle-Valve-Closed-Loop-Control
  saakethramoju/ROCETS-DEV
  saakethramoju/Engine-Data-Analysis
  saakethramoju/Fluid-Network-Analysis-Lecture
  saakethramoju/Contour-Generator
  saakethramoju/Combustion-Chamber-Optimizer
  saakethramoju/TCA-Design-Part-1-Bootcamp
  saakethramoju/Engine-Design-Guide
  saakethramoju/Light-Switch
  Vinay25112001/eVTOLSizer
)

mkdir -p "$WORKDIR"
cd "$WORKDIR"

for src in "${REPOS[@]}"; do
  name="${src#*/}"
  echo "==> $src -> $OWNER/$name ($VISIBILITY)"

  if gh repo view "$OWNER/$name" >/dev/null 2>&1; then
    echo "    $OWNER/$name already exists; skipping (delete or rename it to re-copy)"
    continue
  fi

  rm -rf "$name.git"
  # A bare clone gets every branch and tag. Don't use --mirror: it also fetches
  # GitHub's read-only refs/pull/* refs, which GitHub rejects on push.
  git clone --bare "https://github.com/$src.git" "$name.git"

  desc="$(gh repo view "$src" --json description -q .description 2>/dev/null || true)"
  gh repo create "$OWNER/$name" "--$VISIBILITY" \
    --description "Copy of $src${desc:+: $desc}"

  git -C "$name.git" push --all  "https://github.com/$OWNER/$name.git"
  git -C "$name.git" push --tags "https://github.com/$OWNER/$name.git"
done

echo "Done. Copies are under https://github.com/$OWNER"
