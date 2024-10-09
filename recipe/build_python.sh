set -ex

source $RECIPE_DIR/build.sh

# Python package...
for whl_file in build-ci/Release/dist/onnxruntime*.whl; do
    python -m pip install "$whl_file"
done
# if $SP_DIR/onnxruntime doesn't exist here, the installation
# of onnxruntime (see build.sh call above) failed
pushd $SP_DIR/onnxruntime/capi

# Make symlinks for libraries and headers from libtorch into $SP_DIR/torch
# Also remove the vendorered libraries they seem to include
# https://github.com/conda-forge/pytorch-cpu-feedstock/issues/243
# https://github.com/pytorch/pytorch/blob/v2.3.1/setup.py#L341
for f in *${SHLIB_EXT}; do
  if [[ -e "$PREFIX/lib/$f" ]]; then
    echo Removing $f because it already exists in PREFIX/lib
    rm -rf $f
    ln -sf $PREFIX/lib/$f $PWD/$f
  fi
done

