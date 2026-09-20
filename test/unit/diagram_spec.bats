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
#       prolog - declaration, comments, DOCTYPE) is <svg, not merely "an
#       <svg appears somewhere";
#     - contain NO <foreignObject>: draw.io's default HTML labels export as
#       foreignObject, which GitHub refuses to render ("Text is not SVG -
#       cannot display"), so every label must be plain SVG text (mxGraph
#       style without html=1);
#     - embed the draw.io source the way the desktop exporter writes it
#       with --embed-diagram: exactly ONE content="..." attribute whose
#       value starts with &lt;mxfile and ends with &lt;/mxfile&gt; (the
#       pair sits in the same attribute, opening first, and neither tag
#       occurs anywhere else in the file), otherwise the payload is
#       truncated or stray, the file is a dead picture nobody can edit, and
#       a separate .drawio would become a second source of truth.
#   README.md must reference all three files, and the recommended VS Code
#   extension list must name the editor.
#
#   Wording guard (issue #163): the flow diagram's `just test` node (cell
#   id f_test) must not claim "host 不裝任何套件" - the host DOES need
#   docker + just (and the architecture diagram / README say so). Its label
#   reads "測試依賴皆在 Docker 內 / (host 只需 docker + just)" instead, split
#   over two lines so it fits the 190px node. The check is scoped to the
#   f_test cell - both its rendered <g data-cell-id="f_test"> group and its
#   embedded <mxCell id="f_test"> source - so moving the correct phrase to
#   another node while f_test regresses is caught.
#
#   The "rejects bad input" cases feed hand-written fixtures (a non-root
#   <svg>, a truncated mxfile payload, the phrase moved to another cell) to
#   the same predicates the real diagrams go through, so the guards are
#   proven to reject what they claim to reject rather than merely to pass
#   on today's exports.
#
# Written test-first: RED while doc/diagram/ is missing, GREEN once the
# exports and the README section land. The #163 tightening was RED on the
# wording case until flow.drawio.svg was re-exported; the fixture cases were
# RED against the previous global-grep assertions.

load "${BATS_TEST_DIRNAME}/../helper/common"

DIAGRAM_DIR="doc/diagram"
DIAGRAM_NAMES=(architecture flow milestone)

# The four label lines of the flow diagram's `just test` node, in order.
F_TEST_LINE_1="2. just test"
F_TEST_LINE_2="六道 gate,全部在 Docker"
F_TEST_LINE_3="測試依賴皆在 Docker 內"
F_TEST_LINE_4="(host 只需 docker + just)"
OLD_F_TEST_WORDING="host 不裝任何套件"

setup() {
    README="${REPO_ROOT}/README.md"
    EXTENSIONS_JSON="${REPO_ROOT}/.vscode/extensions.json"
}

# Absolute path of diagram $1.
_svg() {
    printf '%s/%s/%s.drawio.svg\n' "${REPO_ROOT}" "${DIAGRAM_DIR}" "$1"
}

# --- Predicates (shared by the real diagrams and the fixtures) ---------------

# Name of the first element in file $1 (the first "<" followed by a name
# character): the XML declaration (<?xml) and the DOCTYPE (<!DOCTYPE) are
# skipped because they are not elements, and comments are removed whole
# (XML forbids "--" inside a comment, so the pattern is exact) so a tag
# name mentioned in a comment does not count.
_first_element() {
    tr -d '\n' < "$1" \
        | sed -E 's/<!--([^-]|-[^-])*-->//g' \
        | grep -oE '<[A-Za-z][A-Za-z0-9:_.-]*' | head -n 1
}

# True iff file $1 is an SVG document: its root element is <svg>.
_is_svg_document() {
    [ "$(_first_element "$1")" = "<svg" ]
}

# The content="..." attribute(s) of file $1, one per line (draw.io writes the
# embedded mxfile there; attribute values are &quot;-escaped, so the value
# never contains a raw double quote). Newlines are dropped first so an
# attribute spanning lines still comes out whole.
_content_attrs() {
    tr -d '\n' < "$1" | grep -oE 'content="[^"]*"'
}

# True iff file $1 embeds one draw.io source the way --embed-diagram writes
# it: exactly one content="..." attribute, its value opening with &lt;mxfile
# and closing with &lt;/mxfile&gt; (the exporter leaves an escaped newline,
# &#10;, after the closing tag; trailing escaped/plain whitespace is
# ignored), and neither tag anywhere else.
_embeds_mxfile() {
    local _f="$1" _attrs
    _attrs="$(_content_attrs "${_f}")" || return 1
    [ "$(printf '%s\n' "${_attrs}" | wc -l)" -eq 1 ] || return 1
    _attrs="$(printf '%s' "${_attrs}" | sed -E 's/(&#10;|&#xa;|[[:space:]])*"$/"/')"
    case "${_attrs}" in
        'content="&lt;mxfile'*'&lt;/mxfile&gt;"') ;;
        *) return 1 ;;
    esac
    [ "$(grep -o '&lt;mxfile' "${_f}" | wc -l)" -eq 1 ] || return 1
    [ "$(grep -o '&lt;/mxfile&gt;' "${_f}" | wc -l)" -eq 1 ]
}

# Rendered group of cell $2 in file $1: from <g data-cell-id="$2"> up to the
# next data-cell-id group (draw.io emits the groups as siblings, one per
# cell). Newlines are dropped first so the match spans the whole document.
_rendered_cell() {
    tr -d '\n' < "$1" \
        | grep -o "<g data-cell-id=\"$2\">.*" \
        | sed -E "s/^<g data-cell-id=\"$2\">//; s/<g data-cell-id=\"[^\"]*\">.*$//"
}

# Label lines of rendered cell $2 in file $1: one line per <text> element,
# document order.
_cell_label_lines() {
    _rendered_cell "$1" "$2" \
        | grep -oE '<text[^>]*>[^<]*</text>' \
        | sed -E 's/<text[^>]*>//; s/<\/text>$//'
}

# Embedded source of cell $2 in file $1: the &lt;mxCell id=&quot;$2&quot;
# element (HTML-escaped inside the content attribute) up to its closing tag.
_source_cell() {
    tr -d '\n' < "$1" \
        | grep -o "&lt;mxCell id=&quot;$2&quot;.*" \
        | sed -E 's/&lt;\/mxCell&gt;.*$//'
}

# --- Fixtures (written under BATS_TEST_TMPDIR) ------------------------------

# $1 = path. An <svg> that is NOT the root element (wrapped in <html>).
_write_fixture_svg_not_root() {
    cat > "$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!-- <svg mentioned in a comment does not count either -->
<html><body><svg xmlns="http://www.w3.org/2000/svg"><text>x</text></svg></body></html>
EOF
}

# $1 = path. A root <svg> whose content attribute opens &lt;mxfile but never
# closes it; a stray &lt;/mxfile&gt; sits in a comment outside the attribute,
# so "opening somewhere + closing somewhere" is satisfied but the payload is
# truncated.
_write_fixture_mxfile_truncated() {
    cat > "$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" content="&lt;mxfile host=&quot;x&quot;&gt;&lt;diagram&gt;&lt;mxGraphModel&gt;&lt;root&gt;"><!-- &lt;/mxfile&gt; --><text>x</text></svg>
EOF
}

# $1 = path. A flow-shaped SVG where the f_test cell carries the OLD wording
# while the correct two lines were moved to another cell (f_other), in both
# the rendered groups and the embedded source. A global grep for the new
# phrase passes; only a cell-scoped check catches the regression.
_write_fixture_wording_moved() {
    cat > "$1" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<svg xmlns="http://www.w3.org/2000/svg" content="&lt;mxfile host=&quot;x&quot;&gt;&lt;diagram&gt;&lt;mxGraphModel&gt;&lt;root&gt;&lt;mxCell id=&quot;f_test&quot; value=&quot;2. just test&amp;#xa;六道 gate,全部在 Docker&amp;#xa;host 不裝任何套件&quot; vertex=&quot;1&quot;&gt;&lt;mxGeometry as=&quot;geometry&quot; /&gt;&lt;/mxCell&gt;&lt;mxCell id=&quot;f_other&quot; value=&quot;測試依賴皆在 Docker 內&amp;#xa;(host 只需 docker + just)&quot; vertex=&quot;1&quot;&gt;&lt;mxGeometry as=&quot;geometry&quot; /&gt;&lt;/mxCell&gt;&lt;/root&gt;&lt;/mxGraphModel&gt;&lt;/diagram&gt;&lt;/mxfile&gt;">
<g data-cell-id="f_test"><g><text x="1" y="1">2. just test</text><text x="1" y="2">六道 gate,全部在 Docker</text><text x="1" y="3">host 不裝任何套件</text></g></g>
<g data-cell-id="f_other"><g><text x="1" y="1">測試依賴皆在 Docker 內</text><text x="1" y="2">(host 只需 docker + just)</text></g></g>
</svg>
EOF
}

# --- each diagram: exists, is SVG, no foreignObject, embeds the mxfile ------

@test "the three draw.io SVG diagrams exist and are non-empty" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        assert [ -s "$(_svg "${_n}")" ]
    done
}

@test "each diagram is an SVG document (the first element after the XML prolog is <svg)" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run _first_element "$(_svg "${_n}")"
        assert_success
        assert_output "<svg"
        run _is_svg_document "$(_svg "${_n}")"
        assert_success
    done
}

@test "the SVG-document check rejects a file whose <svg> is not the root element" {
    local _f="${BATS_TEST_TMPDIR}/not_root.svg"
    _write_fixture_svg_not_root "${_f}"
    # A plain "an <svg appears somewhere" grep would accept it ...
    run grep -c '<svg' "${_f}"
    assert_success
    # ... the root-element predicate must not.
    run _is_svg_document "${_f}"
    assert_failure
}

@test "no diagram contains a <foreignObject> (GitHub cannot render draw.io HTML labels)" {
    local _n
    for _n in "${DIAGRAM_NAMES[@]}"; do
        run grep -c '<foreignObject' "$(_svg "${_n}")"
        assert_failure
        assert_output "0"
    done
}

@test "each diagram embeds its draw.io source as one content=\"&lt;mxfile ... &lt;/mxfile&gt;\" pair, so the SVG is the single source" {
    local _n _f
    for _n in "${DIAGRAM_NAMES[@]}"; do
        _f="$(_svg "${_n}")"
        run _embeds_mxfile "${_f}"
        assert_success
        # Exactly one opening and one closing tag in the whole file: the
        # pair is neither duplicated nor left dangling.
        run grep -o '&lt;mxfile' "${_f}"
        assert_success
        assert [ "${#lines[@]}" -eq 1 ]
        run grep -o '&lt;/mxfile&gt;' "${_f}"
        assert_success
        assert [ "${#lines[@]}" -eq 1 ]
    done
}

@test "the mxfile check rejects a truncated payload (closing tag outside the content attribute)" {
    local _f="${BATS_TEST_TMPDIR}/truncated.svg"
    _write_fixture_mxfile_truncated "${_f}"
    # Opening and closing strings each occur once somewhere ...
    run grep -c 'content="&lt;mxfile' "${_f}"
    assert_output "1"
    run grep -c '&lt;/mxfile&gt;' "${_f}"
    assert_output "1"
    # ... but the closing tag is not the end of the content attribute.
    run _embeds_mxfile "${_f}"
    assert_failure
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

@test "flow diagram: the old 'host installs nothing' wording is gone from the whole file" {
    run grep -c "${OLD_F_TEST_WORDING}" "$(_svg flow)"
    assert_failure
    assert_output "0"
}

@test "flow diagram: the rendered f_test node carries exactly the four expected label lines" {
    run _cell_label_lines "$(_svg flow)" f_test
    assert_success
    assert [ "${#lines[@]}" -eq 4 ]
    assert_line --index 0 "${F_TEST_LINE_1}"
    assert_line --index 1 "${F_TEST_LINE_2}"
    assert_line --index 2 "${F_TEST_LINE_3}"
    assert_line --index 3 "${F_TEST_LINE_4}"
}

@test "flow diagram: the embedded f_test source value carries the same four lines (editor re-export keeps the wording)" {
    run _source_cell "$(_svg flow)" f_test
    assert_success
    assert_output --partial "value=&quot;${F_TEST_LINE_1}&amp;#xa;${F_TEST_LINE_2}&amp;#xa;${F_TEST_LINE_3}&amp;#xa;${F_TEST_LINE_4}&quot;"
    refute_output --partial "${OLD_F_TEST_WORDING}"
}

@test "the wording check rejects a flow where f_test regressed and the phrase moved to another cell" {
    local _f="${BATS_TEST_TMPDIR}/moved.svg"
    _write_fixture_wording_moved "${_f}"
    # A global grep still finds the new phrase, in rendered text and source ...
    run grep -o "${F_TEST_LINE_3}" "${_f}"
    assert_success
    assert [ "${#lines[@]}" -ge 2 ]
    # ... but the f_test node itself carries the old wording.
    run _cell_label_lines "${_f}" f_test
    assert_success
    refute_line "${F_TEST_LINE_3}"
    refute_line "${F_TEST_LINE_4}"
    assert_line "${OLD_F_TEST_WORDING}"
    run _source_cell "${_f}" f_test
    assert_success
    refute_output --partial "${F_TEST_LINE_3}"
    assert_output --partial "${OLD_F_TEST_WORDING}"
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
