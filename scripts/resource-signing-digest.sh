#!/bin/zsh
# Xcode tracks this declared bundle output as an input to its normal CodeSign
# task. Resource-only changes must not leave a previously signed app unsealed.
set -euo pipefail
export LC_ALL=C
die() { print -u2 -- "Resource signing digest: $*"; exit 1; }
[[ $# == 2 ]] || die 'usage: resource-signing-digest.sh RESOURCE_DIRECTORY OUTPUT_FILE'
resource_root=${1:A}
output_file=${2:A}
[[ -d "$resource_root" && ! -L "$1" ]] || die 'resource directory must be a real directory'
[[ "$output_file" != "$resource_root" && "$output_file" != "$resource_root"/* ]] || die 'output must be outside the source resources'
[[ ! -L "$2" && -d "${output_file:h}" ]] || die 'output must have an existing parent and must not be a symlink'
cd "$resource_root"
# The phase runs each build to detect new/deleted files too. Do not follow
# symlinks into other source trees or user data. Include dotfiles and filenames
# with spaces/newlines; paths are relative so moving the checkout is harmless.
resource_links=(**/*(DN@))
(( ${#resource_links} == 0 )) || die 'symlink resources are not supported'
resource_files=(**/*(DN.))
(( ${#resource_files} > 0 )) || die 'resource directory is empty'
digest=$({
  for resource_file in "${resource_files[@]}"; do
    print -rn -- "$resource_file"$'\0'
    /usr/bin/shasum -a 256 < "$resource_file"
  done
} | /usr/bin/shasum -a 256)
digest=${digest%% *}
# Preserve mtime on no-op builds; do not re-sign an unchanged product.
if [[ -f "$output_file" && "$(< "$output_file")" == "$digest" ]]; then
  exit 0
fi
print -r -- "$digest" > "$output_file"
