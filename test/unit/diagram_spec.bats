#!/usr/bin/env bats
# test/unit/diagram_spec.bats - doc/diagram/*.drawio.svg single-source guard
# (issue #151: README architecture / flow / milestone diagrams)
#
# WHAT THIS PROVES
#   Each of the three README diagrams is delivered as ONE editable draw.io
#   SVG (doc/diagram/<name>.drawio.svg) that GitHub can render inline and
#   the draw.io editors (app.diagrams.net, VS Code hediet.vscode-drawio) can
#   open in place. That single file is the single source of truth, so it
#   must:
#     - exist and be an SVG document;
#     - contain NO <foreignObject>: draw.io's default HTML labels export as
#       foreignObject, which GitHub refuses to render ("Text is not SVG -
#       cannot display"), so every label must be plain SVG text (mxGraph
#       style without html=1);
#     - embed the draw.io source (an <mxfile ...> element, or the
#       content="&lt;mxfile ..." attribute the desktop exporter writes with
#       --embed-diagram), otherwise the file is a dead picture nobody can
#       edit and a separate .drawio would become a second source of truth.
#   README.md must reference all three files, and the recommended VS Code
#   extension list must name the editor.
#
# Written test-first: RED while doc/diagram/ is missing, GREEN once the
# exports and the README section land.

load "${BATS_TEST_DIRNAME}/../helper/common"

DIAGRAM_DIR="doc/diagram"
DIAGRAM_NAMES=(architecture flow milestone)

setup() {
    README="${REPO_ROOT}/README.md"
    EXTENSIONS_JSON="${REPO_ROOT}/.vscode/extensions.json"
}

# Absolute path of diagram $1.
_svg() {
    printf '%s/%s/%s.drawio.svg\n' "${REPO_ROOT}" "${DIAGRAM_DIR}" "$1"
}

# --- each diagram: exists, is SVG, no foreignObject, embeds the mxfile ------

@test "the three draw.io SVG diagrams exist and are non-empty" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        assert [ -s "$(_svg "${_n}")" ]
    done
}

@test "each diagram is an SVG document (root <svg> element)" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run grep -c '<svg' "$(_svg "${_n}")"
        assert_success
        assert [ "${output}" -ge 1 ]
    done
}

@test "no diagram contains a <foreignObject> (GitHub cannot render draw.io HTML labels)" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run grep -c '<foreignObject' "$(_svg "${_n}")"
        assert_failure
        assert_output "0"
    done
}

@test "each diagram embeds its draw.io source (mxfile), so the SVG is the single source" {
    local _n _f
    for _n in "${DIAGRAM_NAMES[@]}"; do
        _f="$(_svg "${_n}")"
        run grep -cE 'content="&lt;mxfile|<mxfile' "${_f}"
        assert_success
        assert [ "${output}" -ge 1 ]
    done
}

@test "each diagram carries plain SVG <text> labels (not html=1 styles)" {
    local _n _f
    for _n in "${DIAGRAM_NAMES[@]}"; do
        _f="$(_svg "${_n}")"
        run grep -c '<text' "${_f}"
        assert_success
        assert [ "${output}" -ge 1 ]
        # The embedded source must not carry html=1 either; otherwise a
        # re-export from the editor would bring foreignObject back.
        run grep -c 'html=1\|html%3D1' "${_f}"
        assert_failure
        assert_output "0"
    done
}

# --- README embeds all three -------------------------------------------------

@test "README.md references all three diagram files" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run grep -c "${DIAGRAM_DIR}/${_n}.drawio.svg" "${README}"
        assert_success
        assert [ "${output}" -ge 1 ]
    done
}

@test "README.md embeds each diagram as an image wrapped in an app.diagrams.net edit link" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run grep -cE "\[!\[[^]]*\]\(${DIAGRAM_DIR}/${_n}\.drawio\.svg\)\]\(https://app\.diagrams\.net/\?url=[^)]*${_n}\.drawio\.svg\)" "${README}"
        assert_success
        assert [ "${output}" -ge 1 ]
    done
}

# --- editor recommendation ---------------------------------------------------

@test ".vscode/extensions.json recommends hediet.vscode-drawio" {
    assert [ -f "${EXTENSIONS_JSON}" ]
    run grep -c '"hediet.vscode-drawio"' "${EXTENSIONS_JSON}"
    assert_success
    assert [ "${output}" -ge 1 ]
}

# --- this spec is a required unit spec ---------------------------------------

@test "this spec is a required unit spec of test.sh" {
    run bash -c 'source "$1" && _required_specs unit' _ "${REPO_ROOT}/script/test/test.sh"
    assert_success
    assert_line "unit/$(basename -- "${BATS_TEST_FILENAME}")"
}
