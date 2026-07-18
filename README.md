# cddl-map

`cddl-map` extracts declared CBOR EDN/CDN and CDDL blocks from RFCXML, materializes their dependency graph, and validates them with Carsten Bormann's [`cddlc`](https://github.com/cabo/cddlc).

**`cddlc` is the sole semantic engine.** `cddl-map` does not parse CDDL, build a CDDL AST, resolve CDDL names, or parse/rewrite EDN. It only resolves documents, selects XML character data, stages files and `;# include` wrappers, invokes `cddlc`, and reports its result.

This MVP targets Linux with Ruby 3.2 or newer. It pins `cddlc` 0.4.5 and the validator dependencies that version does not declare itself.

## Scope

Goals:

- reproducibly map RFCXML `<sourcecode>` and legacy `<artwork>` blocks to named CDDL blocks and EDN sets;
- express same-document and cross-document CDDL dependencies;
- detect document, selector, and selected-text drift;
- run cddlc CDDL 2/module processing, undefined-name checks, EDN parsing, and validation;
- provide contextual human diagnostics and JSON output.

Non-goals include parsing HTML or plain-text RFCs, discovering selectors, caching or vendoring remote documents, interpreting CDDL/EDN, and supporting Windows.

## Manifest version 1

The safe-loaded YAML is validated against
[`schema/manifest-v1.schema.yml`](schema/manifest-v1.schema.yml) with
`json_schemer`; unknown keys and wrong types are errors. Identifiers use
letters, digits, `.`, `_`, and `-`.

```yaml
version: 1

documents:
  draft:
    path: draft-example.xml       # relative to this manifest
    # sha256: optional for local files
  cose:
    rfc: 9052                     # canonical RFCXML from rfc-editor.org
  remote-draft:
    url: https://www.ietf.org/archive/id/draft-example-03.xml
    sha256: 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef

cddl:
  common:
    document: draft
    selector:
      section: {anchor: data-model}
      block: {anchor: common-cddl}
  cose-headers:
    document: cose
    selector:
      section: {pn: section-3}
      block: {type: cddl, ordinal: 1}
  message:
    document: draft
    selector:
      section: {anchor: wire-format}
      block: {name: message.cddl}
    depends_on: [common, cose-headers]

edn:
  accepted:
    document: draft
    selector:
      section: {anchor: examples}
      block: {type: cbor-diag, all: true}
    cddl: message                 # a name or a non-empty list of names
    entry_rule: Message
    expect: accept
  rejected:
    document: draft
    selector:
      section: {anchor: invalid-examples}
      block: {pn: section-appendix.a-1}
    cddl: [message]
    entry_rule: Message
    expect: reject
```

Each document has exactly one source:

| Key | Meaning |
| --- | --- |
| `path` | Local RFCXML path, resolved relative to the manifest. |
| `rfc` | Positive RFC number, resolved as `https://www.rfc-editor.org/rfc/rfcNNNN.xml`. |
| `url` | HTTP(S) RFCXML URL. It needs `sha256`, an existing lock entry, or an initial `--update-lock` run. |

`sha256`, when present, pins the fetched XML bytes before parsing. The document map key is its stable identity inside the manifest and lockfile.

### Selectors

A selector first chooses exactly one `<section>` by author `anchor` or generated `pn`. It then considers descendant `<sourcecode>` and `<artwork>` elements in document order. `anchor`, `name`, `pn`, and `type` are exact, case-sensitive attribute filters combined with AND.

- With no mode, the block filters must match exactly one element.
- `ordinal: N` chooses the one-based Nth filtered match.
- `all: true` explicitly chooses every filtered match.
- `ordinal` and `all` are mutually exclusive; zero matches always fail.

Extracted XML character data is written without trimming, dedenting, newline insertion, or EDN/CDDL rewriting. XML-defined entity and newline processing has already occurred in the RFCXML parser. An `all` CDDL selection preserves each source element in a separate deterministic part file and joins them only through cddlc `;# include` directives.

### Dependencies and cddlc

Every named CDDL block has explicit `depends_on` edges. For each schema root, `cddl-map` walks the reachable graph dependency-first, emits every block once, and generates a root wrapper containing cddlc-native `;# include module-name` lines. Same-document and cross-document edges are identical after extraction.

Graph cycles are **not** rejected: the finite wrapper includes each declared block once and cddlc decides whether the resulting recursive CDDL is semantically valid. Source blocks remain untouched, so their own cddlc CDDL 2 `;# include`/`import` directives are processed by cddlc as well.

Each run uses a fresh temporary staging directory and invokes cddlc from inside it with relative filenames and `CDDL_INCLUDE_PATH=.:`. The leading `.` exposes staged modules; the trailing empty entry retains cddlc's curated RFC module collection.

The authoritative commands are equivalent to:

```console
cddlc -u -2 -t cddl schema.cddl
cddlc -2 -s EntryRule -d example.edn schema.cddl
```

Every named CDDL root is checked. Each EDN item is then validated against its declared root collection and entry rule.

## Reproducibility and lockfiles

The default lockfile is the manifest name with `.lock.yml`, for example `examples.yml` becomes `examples.lock.yml`. It records resolved source identities and document SHA-256 values plus every normalized selector, selected element identity, position, and extracted-text SHA-256.

```console
bundle exec cddl-map validate --update-lock examples.yml
bundle exec cddl-map validate --locked examples.yml
```

An existing lockfile is always verified. `--locked` additionally requires one to exist. `--update-lock` replaces it only after all schema checks and expected example results succeed. Thus both draft content drift and selector drift fail before cddlc runs.

## CLI and diagnostics

```console
bundle install
bundle exec cddl-map validate [--locked | --update-lock] [--lock PATH] \
  [--cddlc PATH] [--json] MANIFEST
```

Exit status is zero only when extraction, lock verification, all schema checks, and all expected outcomes succeed. Human errors include the document ID, logical selection, selector, cddlc command/exit status, and captured stdout/stderr where applicable. `--json` emits one object with `ok` and either `result` or `error`.

Current cddlc CLI constraints are intentionally visible:

- `cddlc -u -t cddl` reports undefined names on stdout but can exit zero, so `cddl-map` treats `;;; *** undefined:` output as failure.
- Schema-check stderr is treated as failure because cddlc reports module/directive problems there without consistently changing exit status.
- Validation failure details are cddlc's unstable YAML diagnostic dump. `cddl-map` does not parse that structure; it only uses the YAML document marker to distinguish a schema rejection from EDN parse/runtime failure.
- cddlc's validator is still a preview and does not implement every CDDL construct. Those limitations are cddlc limitations, not replaced with local semantics.

## Development

```console
bundle exec rake test
bundle exec rake build
```

Tests use a fake cddlc for deterministic orchestration coverage and run a real-cddlc smoke test whenever the pinned executable is installed.
