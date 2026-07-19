# cddl-map

RFCs and Internet-Drafts often split CDDL schemas and CBOR examples across
multiple XML blocks or documents. `cddl-map` is a declarative wiring layer:
it extracts declared EDN/CDN and CDDL blocks from RFCXML, materializes their
dependency graph, and validates them with Carsten Bormann's
[`cddlc`](https://github.com/cabo/cddlc).

**`cddlc` is the sole semantic engine.** `cddl-map` does not parse CDDL, build a CDDL AST, resolve CDDL names, or parse/rewrite EDN. It only resolves documents, selects XML character data, stages files and `;# include` wrappers, invokes `cddlc`, and reports its result.

This MVP targets Linux with Ruby 3.2 or newer. It pins `cddlc` 0.4.5 and the validator dependencies that version does not declare itself.

## How it works

1. A YAML manifest names source documents, CDDL blocks, dependencies, and EDN sets.
2. Exact RFCXML character data is selected without rewriting the CDDL or EDN.
3. The declared graph becomes deterministic cddlc `;# include` and `;# import` modules in an isolated directory.
4. cddlc performs schema/module checks and validates each example against its entry rule.
5. An optional lockfile records source and selector identities to detect remapping.

## Scope

Goals:

- declaratively map RFCXML `<sourcecode>` and legacy `<artwork>` blocks to named CDDL blocks and EDN sets;
- express same-document and cross-document CDDL dependencies;
- resolve collision-safe cross-document CDDL imports;
- detect source, selector, and selected-element identity drift;
- run cddlc CDDL 2/module processing, undefined-name checks, EDN parsing, and validation;
- render the declared validation graph as Mermaid grouped by source document;
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
  cose:
    rfc: 9052                     # canonical RFCXML from rfc-editor.org
  remote-draft:
    url: https://www.ietf.org/archive/id/draft-example-03.xml

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
| `url` | HTTP(S) RFCXML URL. |

The document map key is its stable identity inside the manifest and lockfile.

### Selectors

A selector first chooses exactly one `<section>` by author `anchor` or generated `pn`. It then considers descendant `<sourcecode>` and `<artwork>` elements in document order. `anchor`, `name`, `pn`, and `type` are exact, case-sensitive attribute filters combined with AND.

- With no mode, the block filters must match exactly one element.
- `ordinal: N` chooses the one-based Nth filtered match.
- `all: true` explicitly chooses every filtered match.
- `ordinal` and `all` are mutually exclusive; zero matches always fail.

Extracted XML character data is written without trimming, dedenting, newline insertion, or EDN/CDDL rewriting. XML-defined entity and newline processing has already occurred in the RFCXML parser. An `all` CDDL selection preserves each source element in a separate deterministic part file and joins them only through cddlc `;# include` directives.

### Dependencies, imports, and cddlc

Every named CDDL block can have explicit `depends_on` and `imports` edges. `depends_on` eagerly composes complete blocks with cddlc-native `;# include module-name` directives. Each `imports` target is first composed with its own `depends_on` closure, then loaded after the root and its includes. A string emits an unscoped cddlc import, which copies only undefined rules without discarding eager augmentations or overwriting local rules. `{cddl: block-name, rules: [Rule1, Rule2]}` emits an explicit rule-scoped import; as in cddlc, selected rules replace same-named local rules, so list only names intentionally supplied by that target. Nested and repeated imports retain declaration order. Same-document and cross-document edges are identical after extraction.

`depends_on` cycles are **not** rejected: the finite wrapper emits each eagerly reachable block once and cddlc decides whether the resulting recursive CDDL is semantically valid. An `imports` cycle outside the eager root is rejected because cddlc's lazy imports are order-dependent and cannot be resolved to a deterministic fixed point. Source blocks remain untouched, so their own cddlc CDDL 2 `;# include`/`import` directives are processed by cddlc as well.

Each run uses a fresh temporary staging directory and invokes cddlc from inside it with relative filenames and `CDDL_INCLUDE_PATH=.:`. The leading `.` exposes staged modules; the trailing empty entry retains cddlc's curated RFC module collection.

The authoritative commands are equivalent to:

```console
cddlc -u -2 -t cddl schema.cddl
cddlc -2 -s EntryRule -d example.edn schema.cddl
```

Every named CDDL root is checked. Each EDN item is then validated against its declared root collection and entry rule. `expect: skip` still extracts and locks a deliberately illustrative EDN block but does not send it to cddlc; use it only when the published text is intentionally abbreviated or otherwise not a machine-readable test vector.

### Manifest diagrams

`diagram` reads only the manifest and renders its document groups, CDDL dependency/import edges, and EDN-to-CDDL validation edges:

```console
bundle exec cddl-map diagram examples.yml
bundle exec cddl-map diagram --markdown --output examples.md examples.yml
```

The default output is raw Mermaid. `--markdown` wraps it in a fenced block that GitHub renders directly. Diagram generation does not resolve or fetch any source documents.

### Published RFC example graph

[`examples/cose-transparency.yml`](examples/cose-transparency.yml) maps a current set of related COSE and SCITT specifications. Its checked-in [Mermaid diagram](examples/cose-transparency.md) is generated from the manifest:

| Source block | Wiring |
| --- | --- |
| [RFC 9942](https://www.rfc-editor.org/rfc/rfc9942.html) COSE Receipts | Supplies the `Receipt` rules used by the transparent statement. |
| [RFC 9943](https://www.rfc-editor.org/rfc/rfc9943.html) Signed Statement | Lazily imports the X.509 types from [RFC 9360](https://www.rfc-editor.org/rfc/rfc9360.html). |
| [RFC 9943](https://www.rfc-editor.org/rfc/rfc9943.html) Transparent Statement | Selectively imports its receipt-aware `COSE_Sign1` rule from the RFC 9943 Signed Statement block and `Receipt` from RFC 9942. The local Sign1 shape is based on [RFC 9052](https://www.rfc-editor.org/rfc/rfc9052.html). |
| [RFC 9995](https://www.rfc-editor.org/rfc/rfc9995.html) Hash Envelope | Checks the self-contained [RFC 9052](https://www.rfc-editor.org/rfc/rfc9052.html) COSE_Sign1 specialization alongside the transparency graph. |

The RFC 9942, RFC 9943, and RFC 9995 EDN displays abbreviate cryptographic byte strings with `...`. The manifest marks those selections `expect: skip`, so their selectors and selected-element identities remain locked without pretending they are parseable validation vectors.

## Selection lockfiles

The default lockfile is the manifest name with `.lock.yml`, for example `examples.yml` becomes `examples.lock.yml`. It records resolved source identities plus every normalized selector, selected element identity, and position. Document and extracted-text content is deliberately not pinned; changed content is validated on the next run.

```console
bundle exec cddl-map validate --update-lock examples.yml
bundle exec cddl-map validate --locked examples.yml
```

An existing lockfile is always verified. `--locked` additionally requires one to exist. `--update-lock` replaces it only after all schema checks and expected example results succeed. Source or selector remapping fails before cddlc runs.

## CLI and diagnostics

```console
bundle install
bundle exec cddl-map validate [--locked | --update-lock] [--lock PATH] \
  [--cddlc PATH] [--json] MANIFEST
bundle exec cddl-map diagram [--markdown] [--output PATH] MANIFEST
```

Exit status is zero only when extraction, lock verification, all schema checks, and all expected outcomes succeed. Human errors include the document ID, logical selection, selector, cddlc command/exit status, and captured stdout/stderr where applicable. `--json` emits one object with `ok` and either `result` or `error`.

Current cddlc CLI constraints are intentionally visible:

- `cddlc -u -t cddl` reports undefined names on stdout but can exit zero, so `cddl-map` treats `;;; *** undefined:` output as failure.
- Schema-check stderr is treated as failure because cddlc reports module/directive problems there without consistently changing exit status.
- Validation failure details are cddlc's unstable YAML diagnostic dump. `cddl-map` does not parse that structure; it only uses the YAML document marker to distinguish a schema rejection from EDN parse/runtime failure.
- cddlc's validator is still a preview and does not implement every CDDL construct; in 0.4.5, data validation against CDDL maps reports `UNIMPLEMENTED`. Those limitations are not replaced with local semantics.

## Development

```console
bundle exec rake test
bundle exec rake build
```

Tests use a fake cddlc for deterministic orchestration coverage and run a real-cddlc smoke test whenever the pinned executable is installed.
