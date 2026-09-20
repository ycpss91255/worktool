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
#     - exist and be an SVG document: the first element (skipping the XML
#       declaration, comments and the DOCTYPE) is <svg, not merely "an
#       <svg appears somewhere";
#     - contain NO <foreignObject>: draw.io's default HTML labels export as
#       foreignObject, which GitHub refuses to render ("Text is not SVG -
#       cannot display"), so every label must be plain SVG text (mxGraph
#       style without html=1);
#     - embed the draw.io source the way the desktop exporter writes it
#       with --embed-diagram: a content="&lt;mxfile ..." attribute whose
#       payload round-trips (the closing &lt;/mxfile&gt; is present too),
#       otherwise the file is a dead picture nobody can edit and a separate
#       .drawio would become a second source of truth.
#   README.md must reference all three files, and the recommended VS Code
#   extension list must name the editor.
#
#   Wording guard (issue #163): the flow diagram's `just test` node must not
#   claim "host 不裝任何套件" - the host DOES need docker + just (and the
#   architecture diagram / README say so). It reads
#   "測試依賴皆在 Docker 內 (host 只需 docker + just)" instead, split over two
#   label lines so it fits the 190px node.
#
# Written test-first: RED while doc/diagram/ is missing, GREEN once the
# exports and the README section land. The #163 tightening was RED on the
# wording case until flow.drawio.svg was re-exported.

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

# Name of the first element in file $1 (the first "<" followed by a name
# character): the XML declaration (<?xml), comments (<!--) and the DOCTYPE
# (<!DOCTYPE) are skipped because they are not elements.
_first_element() {
    grep -oE '<[A-Za-z][A-Za-z0-9:_.-]*' "$1" | head -n 1
}

# --- each diagram: exists, is SVG, no foreignObject, embeds the mxfile ------

@test "the three draw.io SVG diagrams exist and are non-empty" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        assert [ -s "$(_svg "${_n}")" ]
    done
}

@test "each diagram is an SVG document (the first element after the XML declaration is <svg)" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run _first_element "$(_svg "${_n}")"
        assert_success
        assert_output "<svg"
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

@test "each diagram embeds its draw.io source (content=\"&lt;mxfile ... &lt;/mxfile&gt;), so the SVG is the single source" {
    local _n _f
    for _n in "${DIAGRAM_NAMES[@]}"; do
        _f="$(_svg "${_n}")"
        # The opening tag sits in the content attribute the exporter writes
        # with --embed-diagram ...
        run grep -c 'content="&lt;mxfile' "${_f}"
        assert_success
        assert [ "${output}" -ge 1 ]
        # ... and the closing tag proves the payload was not truncated, so
        # draw.io can round-trip it.
        run grep -c '&lt;/mxfile&gt;' "${_f}"
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

# --- flow diagram wording (issue #163) ---------------------------------------

@test "flow diagram: the just test node no longer claims the host installs nothing" {
    run grep -c 'host 不裝任何套件' "$(_svg flow)"
    assert_failure
    assert_output "0"
}

@test "flow diagram: the just test node says test deps live in Docker (host only needs docker + just)" {
    local _f
    _f="$(_svg flow)"
    # Rendered label lines (one <text> per line) ...
    run grep -c '>測試依賴皆在 Docker 內</text>' "${_f}"
    assert_success
    assert [ "${output}" -ge 1 ]
    run grep -c '>(host 只需 docker + just)</text>' "${_f}"
    assert_success
    assert [ "${output}" -ge 1 ]
    # ... and the embedded source carries the same two fragments, so an
    # editor re-export keeps the wording.
    run grep -o '測試依賴皆在 Docker 內' "${_f}"
    assert_success
    assert [ "${#lines[@]}" -ge 2 ]
    run grep -o '(host 只需 docker + just)' "${_f}"
    assert_success
    assert [ "${#lines[@]}" -ge 2 ]
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
