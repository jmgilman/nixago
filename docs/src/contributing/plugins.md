# Plugins

Contributing plugins to Nixago is a multi-step process. Fortunately, the design
of Nixago makes these steps relatively straightforward.

## Checklist

The following is a helpful checklist to go over before submitting a PR:

1. Is the plugin named after the tool it supports?
2. Does the plugin have a dedicated directory under [plugins][1]?
3. Was the plugin added to the main [default.nix][2]?
4. Does the plugin have tests written for it?
5. Have the tests been added to the [flake.nix][3] `checks` output?
6. Does the plugin have a dedicated page in the documentation?

If you answered yes to all of the above questions, you are ready to submit a PR!

## Creating a Plugin

Creating a plugin encompasses three primary tasks:

1. Create a CUE file
2. Create the Nix functions
3. Write tests and documentation

You should isolate each plugin to a dedicated directory under [plugins][1]. The
first step is to create a new directory with the plugin's name. The name should
ideally indicate the tool that it supports (i.e., the plugin for the Prettier
formatter is called `prettier`).

The remainder of this section will walk through creating a plugin for the
[pre-commit][4] CLI tool. The plugin will generate a `.pre-commit-config.yaml`
file to configure the pre-commit tool.

### Creating the CUE file

Review the [CUE section](design.md#cue) of the design page for more information
about CUE. Each plugin typically utilizes a single CUE file, although more
advanced cases may require multiple files. The file should be called
`template.cue`.

When creating the CUE file, keep the following in mind:

- The schema defined in the file should be sufficient to prevent most
  configuration mistakes.

- If the supported tool has rich documentation around valid values for each
  configuration field, use constraints to improve the accuracy of the schema.

- Don't be overly strict with the schema definition. The goal is to be helpful
  and not generate many false negatives.

Here is the `template.nix` file for our pre-commit plugin:

```cue
#Config: {
    default_install_hook_types?: [...string]
    default_language_version?: [string]: string
    default_stages?: [...string]
    files?: string
    exclude?: string
    fail_fast?: bool
    minimum_pre_commit_version?: string
    repos: [...#Repo]
}

#Hook: {
    additional_dependencies?: [...string]
    alias?: string
    always_run?: bool
    args?: [...string]
    entry?: string
    exclude?: string
    exclude_types?: [...string]
    files?: string
    id: string
    language?: string
    language_version?: string
    log_file?: string
    name?: string
    stages?: [...string]
    types?: [...string]
    types_or?: [...string]
    verbose?: bool
}

#Repo: {
    repo: string
    rev?: string
    if repo != "local" {
        rev: string
    }
    hooks: [...#Hook]
}

{
    #Config
}
```

This file defines three [definitions][5], notated by the `#` symbol. A
definition is synonymous with a schema or contract. It describes the shape of
valid data through various constraints. Let's break one down:

```cue
#Repo: {
    repo: string
    rev?: string
    if repo != "local" {
        rev: string
    }
    hooks: [...#Hook]
}
```

The `pre-commit-config.yaml` file has a `repos` field which is a list of
repositories that pre-commit should build from. The `#Repo` definition provides
the schema for these entries. Each entry must have a `repo` field which is a
string value. The `rev` field is interesting: it's only optional if the `repo`
field is set to "local". The above sets the `rev` field to optional using the
`?` symbol and then conditonally sets it to required based on the value of
`repo`. Finally, each entry has a list of hooks, denoted by the `[...#Hooks]`
syntax.

```cue
{
    #Config
}
```

This final bit is where we define the elements of the CUE file. This is what
will appear when we evaluate the CUE file. In the above case, we're saying the
input data should be a [struct][6] that conforms to the schema defined by
`#Config`.

We're doing no additional transformations to the incoming data in this case. We
expect the input data to be in the format defined in the
`.pre-commit-config.yaml` file. Since YAML is a superset of JSON, we can easily
ask CUE to evaluate the input and produce a YAML output.

### Creating the Nix Functions

With the CUE file created, the next step is to make our primary Nix function. We
will create a single function for generating our configuration file. First,
let's examine the basic structure of a plugin function:

```nix
{ pkgs, lib }:
{ configData, output ? "file.json", mode ? "link" }:
with pkgs.lib;
let
  # Define input files
  files = [ ./template.cue ];

  # Add ddditional logic here

  # Generate the module
  result = lib.mkTemplate {
    inherit configData files mode output;
  };
in
{
  inherit (result) configFile shellHook;
}
```

It's assumed that all plugin functions are defined in this way. You must use
this as a template to start with and then add logic as needed. Let's break down
this structure to better understand each component.

The function takes two arguments, both of them being attribute sets. The first
attribute set is invisible to the end-user and is instead passed by the internal
flake so that the plugin has access to a copy of `nixpkgs` and the internal
flake `lib` output. The second attribute set is standardized and should contain
the attributes shown. They are explained below:

- **configData**: This is the raw configuration data provided by the end user
- **output**: This is the file path where the generated file will be managed
- **mode**: This determines how the file is managed: the default is `link` that
  instructs the file to be symlinked. However, it can also be changed to `copy`
  instead to maintain a local copy of the generated configuration file.

You should change the default values of the last two attributes as needed. It
makes more sense to maintain a copy of a file rather than a symlink in some
cases. The output path is relative to the current working directory of the user.
Most configuration files reside at the root; however, it's possible to nest the
configuration deeper (i.e., `configs/file.json`).

You are not restricted from adding additional attributes to the second argument.
The only requirement is you keep the three listed above. It's recommended you
document the additional attributes added, including what they do, so that the
end user understands what options are available for controlling the plugin.

The remainder of the function is fairly self-explanatory. We declare the input
files to be passed to `cue eval` in the `files` variable. We conclude with a
call to `lib.mkTemplate`, which contains all of the necessary logic for
generating the output the end user is expecting. This function has additional
arguments that can be passed to customize the result; namely, `shellHookExtra`
for adding additional logic to the generated shell hook and `postBuild` for
adding additional logic after `cue eval` is run. You can also pass other flags
to `cue eval` via the `flags` argument. For more details about this function,
[see here](design.md#templates).

The returned output is standardized and should not be changed. Here is the final
result of our function for the pre-commit plugin:

```nix
{ pkgs, lib }:
{ configData, output ? ".pre-commit-config.yaml", mode ? "link" }:
with pkgs.lib;
let
  files = [ ./template.cue ];
  pre-commit = pkgs.pre-commit;

  # Add an extra hook for reinstalling required stages whenever the file changes
  stages = unique (flatten
    (builtins.map
      (repo: builtins.map
        (hook: optionals (hook ? stages) hook.stages)
        repo.hooks)
      configData.repos) ++ [ "pre-commit" ]);
  stagesStr = builtins.concatStringsSep " " stages;
  shellHookExtra =
    (import ./common.nix { inherit pre-commit stagesStr; }).shellHookExtra;

  # Generate the module
  result = lib.mkTemplate {
    inherit configData files mode output shellHookExtra;
  };
in
{
  inherit (result) configFile shellHook;
}
```

We must take two additional steps for our plugin to be picked up by the flake.
The first is creating a `default.nix` in our plugin directory that exports our
function:

```nix
{ pkgs, lib }:
rec {
  default = mkConfig;

  /* Creates a .pre-commit-config.yaml file for configuring pre-commit.
  */
  mkConfig = import ./mkConfig.nix { inherit pkgs lib; };
}
```

This will allow the `mkConfig` function to be accessible under
`nixago.plugins.{myPlugin}.mkConfig`. Setting the `default` attribute is
recommended; otherwise, the plugin may not play well with the `mkAll` function.
You should set it to the most widely used function.

Finally, we must create an entry in the main `default.nix`:

```nix
{ pkgs, lib }:
{
  # ...

  /* https://github.com/pre-commit/pre-commit
  */
  pre-commit = import ./pre-commit { inherit pkgs lib; };

  # ....
}
```

This function registers the plugin to make it accessible from `nixago.plugins`.

### Writing Tests and Documentation

The final step is to write tests and documentation for the plugin. Tests live in
the [tests][8] directory in a dedicated directory named after the plugin. Tests
are relatively trivial to write.

The first step is to create a `default.nix` which runs the test:

```nix
{ runTest }:
runTest "pre-commit.mkConfig" ./expected.yml {
  repos = [
    {
      repo = "https://github.com/my/repo";
      rev = "1.0";
      hooks = [
        {
          id = "my-hook";
        }
      ];
    }
  ];
}
{ }

```

The `runTest` helper function provided performs most of the underlying work
required to test the plugin. It takes four arguments: the function to call for
the test, the location of the expected test output, the data to pass to the
specified function, and any additional arguments to pass to the plugin function.

The second step is to create the expected output. In this case, the above
invocation should produce the following result:

```yaml
repos:
  - hooks:
      - id: my-hook
    repo: https://github.com/my/repo
    rev: "1.0"
```

The expected result is compared to the generated output, and the test will fail
if there is a difference.

The final step is to add the test to the `checks` output in the `default.nix`
file located at the root of the tests directory:

```nix
{
  # ...
  pre-commit = pkgs.callPackage ./pre-commit { inherit runTest; };
  # ...
}
```

Finally, before submitting a PR, add documentation under the [plugins][9]
section of the documentation. Ensure you cover general usage information about
the plugin, including an example invocation.

[1]: https://github.com/jmgilman/nixago/tree/master/plugins
[2]: https://github.com/jmgilman/nixago/blob/master/plugins/default.nix
[3]: https://github.com/jmgilman/nixago/blob/master/flake.nix
[4]: https://pre-commit.com/
[5]: https://cuetorials.com/overview/types-and-values/#definitions
[6]: https://cuetorials.com/overview/types-and-values/#structs
[7]: https://cuelang.org/docs/integrations/
[8]: https://github.com/jmgilman/nixago/tree/master/tests
[9]: https://github.com/jmgilman/nixago/tree/master/docs/plugins