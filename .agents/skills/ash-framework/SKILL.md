---
name: ash-framework
description: "Use this skill for working with the Ash Framework or any of its extensions. Always consult this when making any domain changes, features or fixes."
metadata:
  managed-by: usage-rules
---

<!-- usage-rules-skill-start -->
## Additional References

### ash

- [ash](references/ash/ash.md)
- [actions](references/ash/actions.md)
- [aggregates](references/ash/aggregates.md)
- [authorization](references/ash/authorization.md)
- [calculations](references/ash/calculations.md)
- [code_interfaces](references/ash/code_interfaces.md)
- [code_structure](references/ash/code_structure.md)
- [data_layers](references/ash/data_layers.md)
- [exist_expressions](references/ash/exist_expressions.md)
- [generating_code](references/ash/generating_code.md)
- [migrations](references/ash/migrations.md)
- [query_filter](references/ash/query_filter.md)
- [querying_data](references/ash/querying_data.md)
- [relationships](references/ash/relationships.md)
- [testing](references/ash/testing.md)

### ash_oban

- [ash_oban](references/ash_oban/ash_oban.md)
- [best_practices](references/ash_oban/best_practices.md)
- [debugging_and_error_handling](references/ash_oban/debugging_and_error_handling.md)
- [defining_triggers](references/ash_oban/defining_triggers.md)
- [multi_tenancy_support](references/ash_oban/multi_tenancy_support.md)
- [scheduled_actions](references/ash_oban/scheduled_actions.md)
- [setting_up_ash_oban](references/ash_oban/setting_up_ash_oban.md)
- [triggering_jobs_programmatically](references/ash_oban/triggering_jobs_programmatically.md)
- [working_with_actors](references/ash_oban/working_with_actors.md)

## Searching Documentation

```sh
mix usage_rules.search_docs "search term" -p ash -p ash_oban -p ash_sqlite -p ash_state_machine
```

## Available Mix Tasks

- `mix ash` - Prints Ash help information
- `mix ash.codegen` - Runs all codegen tasks for any extension on any resource/domain in your application.
- `mix ash.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.gen.base_resource` - Generates a base resource. This is a module that you can use instead of `Ash.Resource`, for consistency.
- `mix ash.gen.change` - Generates a custom change module.
- `mix ash.gen.custom_expression` - Generates a custom expression module.
- `mix ash.gen.domain` - Generates an Ash.Domain
- `mix ash.gen.enum` - Generates an Ash.Type.Enum
- `mix ash.gen.gettext` - Copies Ash's .pot file for error message translation
- `mix ash.gen.preparation` - Generates a custom preparation module.
- `mix ash.gen.resource` - Generate and configure an Ash.Resource.
- `mix ash.gen.validation` - Generates a custom validation module.
- `mix ash.generate_livebook` - Generates a Livebook for each Ash domain
- `mix ash.generate_policy_charts` - Generates a Mermaid Flow Chart for a given resource's policies.
- `mix ash.generate_resource_diagrams` - Generates Mermaid Resource Diagrams for each Ash domain
- `mix ash.gettext.extract` - Extracts Ash error messages into a .pot file
- `mix ash.install` - Installs Ash into a project. Should be called with `mix igniter.install ash`
- `mix ash.manifest.dump` - Dump the Ash app manifest as JSON
- `mix ash.migrate` - Runs all migration tasks for any extension on any resource/domain in your application.
- `mix ash.patch.extend` - Adds an extension or extensions to the given domain/resource
- `mix ash.reset` - Runs all tear down & setup tasks for any extension on any resource/domain in your application.
- `mix ash.rollback` - Runs all rollback tasks for any extension on any resource/domain in your application.
- `mix ash.set.domains` - Dynamically discovers and updates Ash domains in config.exs
- `mix ash.setup` - Runs all setup tasks for any extension on any resource/domain in your application.
- `mix ash.tear_down` - Runs all tear_down tasks for any extension on any resource/domain in your application.
- `mix ash_oban.install` - Installs AshOban and Oban
- `mix ash_oban.install.docs`
- `mix ash_oban.set_default_module_names` - Set module names to their default values for triggers and scheduled actions
- `mix ash_oban.set_default_module_names.docs`
- `mix ash_oban.upgrade`
- `mix ash_sqlite.create` - Creates the repository storage
- `mix ash_sqlite.drop` - Drops the repository storage for the repos in the specified (or configured) domains
- `mix ash_sqlite.generate_migrations` - Generates migrations, and stores a snapshot of your resources
- `mix ash_sqlite.install` - Installs AshSqlite. Should be run with `mix igniter.install ash_sqlite`
- `mix ash_sqlite.migrate` - Runs the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_sqlite.rollback` - Rolls back the repository migrations for all repositories in the provided (or configured) domains
- `mix ash_state_machine.generate_flow_charts` - Generates Mermaid Flow Charts for each resource using `AshStateMachine`
- `mix ash_state_machine.install` - Installs AshStateMachine
- `mix ash_state_machine.install.docs`
<!-- usage-rules-skill-end -->
