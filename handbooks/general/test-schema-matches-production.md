# Test schemas must match production — or be derived from the migrations

**Enforcement:** advisory.

## The rule

**Hand-written test DDL is a second schema, and nothing keeps it in step with the first.** When an integration test creates its own `CREATE TABLE` beside the code instead of running the project's real migrations, that DDL is an independent copy of the schema — and the moment it omits a constraint the code under test depends on (`CHECK`, `NOT NULL`, a foreign key, a `UNIQUE` index), the test passes green while the same code fails against the real, migrated schema.

The failure mode is the worst kind: a **false positive on the exact constraint under test.** The path the test exists to prove is the path that breaks in production, and the green check hides it.

Prefer, in order:

1. **Run the real migrations in the integration harness.** The test then exercises the same schema production has, and this class of drift cannot occur. This is the durable answer; if the harness makes it easy, always do this.
2. **If you hand-roll DDL, it MUST carry every constraint the code under test touches** — every `CHECK`, `NOT NULL`, FK, and `UNIQUE` on the columns the code reads or writes. A hand-rolled table that drops a constraint present in the migration for the same table is a review defect, not a convenience.

## The part that adding constraints to the fixture does NOT fix

Putting the missing `CHECK` into the test DDL fixes *this* instance. It does not fix the class, and it is important not to read it as if it did.

**A constraint enforced only in application code has no migration file for a reviewer to compare against.** The reason a reviewer can catch a schema-level divergence at all is that the real constraint lives in a file they can read next to the fixture. The next version of this bug — where the invariant is a runtime check in the code rather than a `CHECK` clause in a migration — is invisible to that comparison, and no amount of constraint-copying into fixtures will surface it. Two consequences:

- Prefer **schema-level constraints** over application-only invariants wherever the database can express them; it makes the invariant reviewable and keeps the test honest.
- When an invariant genuinely must be application-only, the integration test must assert it **directly** — no migration file will ever reveal a fixture that silently permits the forbidden state.

The durable answer to the whole class is not vigilance about fixtures; it is to **stop maintaining a second schema at all** — derive the test schema from the migrations rather than hand-rolling it beside the code.

## Worked example (the shape to look for)

A self-healing routine wrote a status value the production table's `CHECK (status IN (…))` constraint did not permit. Against the real schema that write raised a constraint violation and aborted the routine — in exactly the fail-safe branch the whole design depended on — and, because the abort came before the routine's later independent actions, it also defeated their independence. The integration test hand-rolled the `status` column **without** the `CHECK`, so every subtest, including the fail-safe one, passed green against a schema that could not reproduce the production failure. The divergence was not adjacent to the subject; it *was* the subject.

## For the reviewer

When a diff adds or changes an integration test that creates its own DDL:

- Compare the hand-rolled table against the migration for the same table. Flag any `CHECK` / `NOT NULL` / FK / `UNIQUE` present in the migration but absent from the test DDL, especially on a column the code under test writes.
- If the code under test writes a constrained column (a status enum, a foreign key), and the test DDL does not carry that constraint, treat the test's green result as unproven for that path.
