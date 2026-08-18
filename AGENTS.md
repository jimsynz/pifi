<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- ex_check_ng-start -->
## ex_check_ng usage
_ex_check_ng_

# ex_check usage rules

ex_check provides the `mix check` task: it runs all of a project's code analysis &
testing tools (compiler, formatter, credo, dialyzer, tests, security scanners, ...) in
parallel with one command, and reports every failure in a single run.

## Running

```
mix check
```

Runs every detected tool. Tools whose package or required files are absent are skipped
automatically — you do not need to configure them. Exit status is non-zero if any tool
fails.

For machine-readable output (preferred when an agent parses results):

```
mix check --format agent              # JSON status header + raw failure blocks
mix check --format json --output check.json
```

Both formats include a `diagnostics` list for failed `compiler`/`credo`/`ex_unit` checks —
each entry has `file`, `line` and `message`, so you can jump straight to a finding instead
of parsing the raw output blocks.

## Useful flags

- `--only NAME` / `-o NAME` — run only the named tool(s); repeatable. e.g. `mix check -o credo -o ex_unit`
- `--except NAME` / `-x NAME` — skip the named tool(s); repeatable.
- `--fix` / `-f` — auto-fix what can be fixed (e.g. `mix format`, unlock unused deps).
- `--retry` / `-r` — run only tools that failed in the previous run.
- `--no-parallel` — run tools sequentially.
- `--config PATH` / `-c PATH` — use a specific config file.
- `--format pretty|agent|json|github|junit` — output format (default `pretty`). `github` emits
  GitHub Actions log groups + a `$GITHUB_STEP_SUMMARY` table; `junit` emits a JUnit XML report.
- `--output PATH` — write the report to a file (only with `--format agent`, `json` or `junit`).

Combine `--fix --retry` to fix only the tools that just failed.

## Configuration: `.check.exs`

Generate a commented starter config:

```
mix check.gen.config
```

`.check.exs` returns a keyword list. Root keys:

- `:tools` — list of tool tuples (overrides/extends the curated set).
- `:fix` — `true` to always run fix mode (default `false`).
- `:parallel` — `false` to disable parallelism (default `true`).
- `:retry` — `false` to disable auto-retry (default: on when a manifest exists).
- `:skipped` — `false` to hide skipped tools in the summary.

Tool tuple forms:

```elixir
{:credo, false}                              # disable a curated tool
{:credo, "mix credo --strict"}               # override the command
{:my_task, "mix my_task"}                    # add a custom mix task
{:my_tool, ["my_tool", "arg with spaces"]}   # add an arbitrary command
{:npm_test, command: "npm test", cd: "assets", env: %{"CI" => "true"}}
```

Example `.check.exs`:

```elixir
[
  tools: [
    {:dialyzer, false},
    {:credo, "mix credo --strict"},
    {:my_audit, "mix my_audit"}
  ]
]
```

Local-only overrides go in `~/.check.exs` (e.g. `[fix: true]`). Umbrella projects run
tools recursively per child app by default; tune via each tool's `:umbrella` option.

## Curated tools

`mix check` runs these when detected:

- `compiler` — `mix compile --warnings-as-errors`
- `formatter` — `mix format --check-formatted` (fix: `mix format`)
- `unused_deps` — `mix deps.unlock --check-unused` (fix: `--unused`)
- `credo` — `mix credo`
- `dialyzer` — `mix dialyzer` (needs `:dialyxir`)
- `doctor` — `mix doctor` (needs `:doctor`)
- `ex_doc` — `mix docs` (needs `:ex_doc`)
- `sobelow` — `mix sobelow --exit` (needs `:sobelow`)
- `mix_audit` — `mix deps.audit` (needs `:mix_audit`)
- `gettext` — `mix gettext.extract --check-up-to-date` (needs `:gettext`)
- `ex_unit` — `mix test` (retry: `mix test --failed`)
- `npm_test` — `npm test` in `assets/` (needs `package.json`)

## Agent guidance

- Run `mix check` before considering an Elixir change complete — it surfaces compile
  warnings, format drift, credo/dialyzer/test failures in one pass.
- Prefer `mix check --format agent` for parseable output.
- Use `mix check --fix` to resolve formatting and unused-dep issues automatically.
- Do not add tools that aren't installed; ex_check auto-skips missing ones.
- To narrow a slow run while iterating, use `-o`/`--only`.

<!-- ex_check_ng-end -->
<!-- usage-rules-end -->
