# frozen_string_literal: true

require_relative "test_helper"

class DiagramTest < Minitest::Test
  def test_groups_nodes_by_document_and_renders_validation_edges
    with_workspace do |workspace|
      manifest_path = workspace.join("map.yml")
      write_manifest(
        manifest_path,
        documents: {
          "alpha" => { "path" => "alpha.xml" },
          "beta" => { "rfc" => 9995 }
        },
        cddl: {
          "base" => cddl_spec(document: "alpha", anchor: "base"),
          "types" => cddl_spec(document: "alpha", anchor: "types"),
          "message" => cddl_spec(
            document: "beta",
            anchor: "message",
            depends_on: ["base"],
            imports: [{ "cddl" => "types", "rules" => ["Imported"] }]
          )
        },
        edn: {
          "example" => edn_spec(
            document: "beta",
            anchor: "example",
            cddl: "message",
            expect: "skip"
          )
        }
      )

      diagram = CddlMap::Diagram.render(CddlMap::Manifest.load(manifest_path.to_s))

      expected = <<~MERMAID
        flowchart LR
          subgraph document_1["alpha<br/>path:alpha.xml"]
            direction TB
            cddl_1["CDDL: base"]
            cddl_2["CDDL: types"]
          end
          subgraph document_2["beta<br/>rfc:9995"]
            direction TB
            cddl_3["CDDL: message"]
            edn_1["EDN: example<br/>entry: Message<br/>expect: skip"]
          end

          cddl_3 -->|"depends_on"| cddl_1
          cddl_3 -.->|"imports: Imported"| cddl_2
          edn_1 -->|"validates against: Message"| cddl_3

          classDef cddl fill:#ddf4ff,stroke:#0969da,color:#1f2328;
          classDef accepted fill:#dafbe1,stroke:#1a7f37,color:#1f2328;
          classDef rejected fill:#ffebe9,stroke:#cf222e,color:#1f2328;
          classDef skipped fill:#fff8c5,stroke:#9a6700,color:#1f2328;
          class cddl_1,cddl_2,cddl_3 cddl;
          class edn_1 skipped;
      MERMAID
      assert_equal expected, diagram
    end
  end
end
