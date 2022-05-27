{ pkgs, lib }:
{
  /* Creates a .pre-commit-config.yaml file for configuring pre-commit.

    See template.cue for the expected format of incoming data.
  */
  mkConfig = import ./make.nix { inherit pkgs lib; };

  /* Like mkConfig except it takes a simplified data input for creating local hooks.

    It's common for pre-commit hooks to be defined locally when using Nix. This
    allows using binaries from the Nix store rather than having pre-commit
    manage them. This function is optimized for this use-case and takes a
    simplified data input. See the docs for more information.
  */
  mkLocalConfig = import ./make_local.nix { inherit pkgs lib; };
}
