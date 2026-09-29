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
#   over two lines so it fits the 190px node. The guard is ONE predicate,
#   _f_test_wording_ok (= _f_test_rendered_ok && _f_test_source_ok), scoped
#   to the f_test cell - its rendered <g data-cell-id="f_test"> group and its
#   embedded <mxCell id="f_test"> source - so moving the correct phrase to
#   another node while f_test regresses is caught.
#
#   The "rejects bad input" cases feed hand-written fixtures (a non-root
#   <svg>, a truncated mxfile payload, the phrase moved to another cell) to
#   the very same predicates the real diagrams go through - never to a
#   separate, weaker check - so the guards are proven to reject what they
#   claim to reject rather than merely to pass on today's exports, and a
#   guard that later degrades to a global grep fails its rejection case. A
#   control fixture (correct f_test) proves the guard accepts the fixture
#   shape at all, so the rejection is not a vacuous format mismatch.
#
#   Box HOME guard (issue #197, ADR 0002): the architecture diagram's HOME
#   cylinder (cell id home) shows the box's own HOME, not the superseded
#   shared HOME. Same shape as the f_test guard: one predicate,
#   _home_cell_ok, checks the rendered group AND the embedded source of that
#   one cell, and the two captions that describe the diagram (README.md and
#   doc/structure.md) no longer say "共用 HOME" either.
#
# Written test-first: RED while doc/diagram/ is missing, GREEN once the
# exports and the README section land. The #163 tightening was RED on the
# wording case until flow.drawio.svg was re-exported; the fixture cases were
# RED against the previous global-grep assertions, and the shared-predicate
# rejection case was RED with the guard temporarily written as a global grep.

load "${BATS_TEST_DIRNAME}/../helper/common"

DIAGRAM_DIR="doc/diagram"
DIAGRAM_NAMES=(architecture flow milestone)

# The four label lines of the flow diagram's `just test` node, in order.
F_TEST_LINE_1="2. just test"
F_TEST_LINE_2="六道 gate,全部在 Docker"
F_TEST_LINE_3="測試依賴皆在 Docker 內"
F_TEST_LINE_4="(host 只需 docker + just)"
OLD_F_TEST_WORDING="host 不裝任何套件"
# A paraphrase of the old claim used by the regression fixture: wrong in
# meaning, yet matched by neither the old string nor the new lines.
REGRESSED_F_TEST_WORDING="host 免安裝"

# The label lines of the architecture diagram's HOME cylinder (#197).
HOME_LINE_1="盒子 HOME(--home)"
HOME_LINE_2="預設 ~/dev-box"
HOME_LINE_3="tool config:fish tmux nvim"
HOME_LINE_4="user config 連結自 host"
HOME_LINE_5="host tool config 不受影響"
OLD_HOME_WORDING="共用 HOME"
# Round-1 wording of line 5: wrong, because user config is symlinked from the
# host (ADR 0002), so editing it in the box does change the host's copy.
OLD_HOME_LINE_5="host 設定不受影響"

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

# --- The #163 wording guard (ONE predicate; real diagram and fixtures) -------
#
# Both halves are scoped to the f_test cell: what other cells say never
# counts, so the correct phrase living elsewhere cannot mask a regressed
# f_test. On failure they print what f_test actually carries, so a failing
# case shows the mismatch instead of a bare exit status.

# The four expected lines, newline-separated, as _cell_label_lines reports.
_f_test_expected_lines() {
    printf '%s\n%s\n%s\n%s\n' \
        "${F_TEST_LINE_1}" "${F_TEST_LINE_2}" "${F_TEST_LINE_3}" "${F_TEST_LINE_4}"
}

# True iff the rendered <g data-cell-id="f_test"> group of file $1 carries
# exactly the four expected <text> lines, in order, and nothing else.
_f_test_rendered_ok() {
    local _got
    _got="$(_cell_label_lines "$1" f_test)"
    [ "${_got}" = "$(_f_test_expected_lines)" ] && return 0
    printf 'rendered f_test lines:\n%s\n' "${_got}"
    return 1
}

# True iff the embedded &lt;mxCell id=&quot;f_test&quot; source of file $1
# has value= exactly the same four lines (joined with &amp;#xa;, the escaped
# newline entity draw.io writes), so an editor re-export keeps the wording.
_f_test_source_ok() {
    local _cell _want
    _cell="$(_source_cell "$1" f_test)"
    _want="value=&quot;$(_f_test_expected_lines | sed -E '$!s/$/\&amp;#xa;/' | tr -d '\n')&quot;"
    case "${_cell}" in
        *"${_want}"*) return 0 ;;
    esac
    printf 'source f_test cell:\n%s\n' "${_cell}"
    return 1
}

# True iff the flow diagram $1 passes the #163 wording guard on both sides.
_f_test_wording_ok() {
    _f_test_rendered_ok "$1" && _f_test_source_ok "$1"
}

# --- The #197 box-HOME guard (architecture diagram, cell id home) ------------

# The five expected lines, newline-separated, as _cell_label_lines reports.
_home_expected_lines() {
    printf '%s\n%s\n%s\n%s\n%s\n' "${HOME_LINE_1}" "${HOME_LINE_2}" \
        "${HOME_LINE_3}" "${HOME_LINE_4}" "${HOME_LINE_5}"
}

# True iff the rendered home group AND the embedded home source of file $1
# both carry exactly the five expected lines; prints the mismatch otherwise.
_home_cell_ok() {
    local _got _cell _want
    _got="$(_cell_label_lines "$1" home)"
    if [ "${_got}" != "$(_home_expected_lines)" ]; then
        printf 'rendered home lines:\n%s\n' "${_got}"
        return 1
    fi
    _cell="$(_source_cell "$1" home)"
    _want="value=&quot;$(_home_expected_lines | sed -E '$!s/$/\&amp;#xa;/' | tr -d '\n')&quot;"
    case "${_cell}" in
        *"${_want}"*) return 0 ;;
    esac
    printf 'source home cell:\n%s\n' "${_cell}"
    return 1
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

# Cell label lines are passed to the fixture writers as ONE newline-separated
# string ($2 below), the way _cell_label_lines reports them.

# One escaped mxCell for the embedded source: id $1, value = the lines $2
# joined with the draw.io newline entity (&#xa;, itself &amp;-escaped inside
# the content attribute).
_fixture_source_cell() {
    local _value
    _value="$(printf '%s\n' "$2" | sed -E '$!s/$/\&amp;#xa;/' | tr -d '\n')"
    printf '&lt;mxCell id=&quot;%s&quot; value=&quot;%s&quot; vertex=&quot;1&quot;&gt;&lt;mxGeometry as=&quot;geometry&quot; /&gt;&lt;/mxCell&gt;' \
        "$1" "${_value}"
}

# One rendered cell group: id $1, one <text> per line of $2.
_fixture_rendered_cell() {
    local _line _y=0
    printf '<g data-cell-id="%s"><g>' "$1"
    while IFS= read -r _line; do
        _y=$((_y + 1))
        printf '<text x="1" y="%s">%s</text>' "${_y}" "${_line}"
    done <<< "$2"
    printf '</g></g>\n'
}

# $1 = path, $2 = f_test lines, $3 = f_other lines. A minimal flow-shaped
# SVG (root <svg>, one embedded mxfile, two cells f_test / f_other) in the
# same shape as the real export: the rendered <g data-cell-id> groups and the
# embedded &lt;mxCell&gt; source agree with each other, so what the guard
# sees is decided by the caller alone.
_write_fixture_flow() {
    {
        printf '<?xml version="1.0" encoding="UTF-8"?>\n'
        printf '<svg xmlns="http://www.w3.org/2000/svg" content="&lt;mxfile host=&quot;x&quot;&gt;&lt;diagram&gt;&lt;mxGraphModel&gt;&lt;root&gt;'
        _fixture_source_cell f_test "$2"
        _fixture_source_cell f_other "$3"
        printf '&lt;/root&gt;&lt;/mxGraphModel&gt;&lt;/diagram&gt;&lt;/mxfile&gt;">\n'
        _fixture_rendered_cell f_test "$2"
        _fixture_rendered_cell f_other "$3"
        printf '</svg>\n'
    } > "$1"
}

# $1 = path. Control fixture: f_test carries the correct four lines and
# f_other something unrelated. Proves the guard accepts a fixture of this
# shape at all, so the rejection below is not a vacuous format mismatch.
_write_fixture_wording_ok() {
    _write_fixture_flow "$1" \
        "${F_TEST_LINE_1}"$'\n'"${F_TEST_LINE_2}"$'\n'"${F_TEST_LINE_3}"$'\n'"${F_TEST_LINE_4}" \
        "3. just box"$'\n'"assemble"
}

# $1 = path. Regression fixture: f_test regressed to a paraphrase of the old
# claim (neither the old string nor the new lines) while the correct two
# lines were moved to f_other, in both the rendered groups and the embedded
# source. Every global grep passes - the new phrase is present, the old
# string is absent - so only a cell-scoped guard catches it.
_write_fixture_wording_moved() {
    _write_fixture_flow "$1" \
        "${F_TEST_LINE_1}"$'\n'"${F_TEST_LINE_2}"$'\n'"${REGRESSED_F_TEST_WORDING}" \
        "${F_TEST_LINE_3}"$'\n'"${F_TEST_LINE_4}"
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
    run _f_test_rendered_ok "$(_svg flow)"
    assert_success
}

@test "flow diagram: the embedded f_test source value carries the same four lines (editor re-export keeps the wording)" {
    run _f_test_source_ok "$(_svg flow)"
    assert_success
}

@test "flow diagram: the real export passes the f_test wording guard as a whole" {
    run _f_test_wording_ok "$(_svg flow)"
    assert_success
}

@test "the wording guard accepts a fixture whose f_test carries the four lines (control)" {
    local _f="${BATS_TEST_TMPDIR}/ok.svg"
    _write_fixture_wording_ok "${_f}"
    run _f_test_wording_ok "${_f}"
    assert_success
}

@test "the wording guard rejects a flow where f_test regressed and the phrase moved to another cell" {
    local _f="${BATS_TEST_TMPDIR}/moved.svg"
    _write_fixture_wording_moved "${_f}"
    # Every global grep passes: the new phrase is there (rendered text and
    # source) and the old string is nowhere ...
    run grep -o "${F_TEST_LINE_3}" "${_f}"
    assert_success
    assert [ "${#lines[@]}" -ge 2 ]
    run grep -c "${OLD_F_TEST_WORDING}" "${_f}"
    assert_failure
    assert_output "0"
    # ... but the guard the real diagram goes through must refuse it, on the
    # rendered side, on the source side, and as a whole. Should the guard
    # ever fall back to a global grep, these three fail.
    run _f_test_rendered_ok "${_f}"
    assert_failure
    run _f_test_source_ok "${_f}"
    assert_failure
    run _f_test_wording_ok "${_f}"
    assert_failure
}

# --- architecture diagram: the box owns its HOME (issue #197) ----------------

@test "architecture diagram: the HOME cell shows the box's own HOME (rendered and source)" {
    run _home_cell_ok "$(_svg architecture)"
    assert_success
}

@test "architecture diagram and its captions no longer say shared HOME" {
    local _f
    for _f in "$(_svg architecture)" "${README}" "${REPO_ROOT}/doc/structure.md"; do
        run grep -c "${OLD_HOME_WORDING}" "${_f}"
        assert_failure
        assert_output "0"
    done
}

@test "the box-HOME guard accepts a fixture HOME cell with the five lines (control)" {
    local _f="${BATS_TEST_TMPDIR}/box_home.svg"
    _write_fixture_flow "${_f}" "$(_home_expected_lines)" "x"
    sed -i 's/f_test/home/g' "${_f}"
    run _home_cell_ok "${_f}"
    assert_success
}

@test "the box-HOME guard rejects a HOME cell that still carries the shared-HOME label" {
    local _f="${BATS_TEST_TMPDIR}/shared_home.svg"
    _write_fixture_flow "${_f}" "${OLD_HOME_WORDING}"$'\n'"~/.config/*" "x"
    sed -i 's/f_test/home/g' "${_f}"
    run _home_cell_ok "${_f}"
    assert_failure
}

@test "architecture diagram no longer claims all host config is unaffected" {
    run grep -c "${OLD_HOME_LINE_5}" "$(_svg architecture)"
    assert_failure
    assert_output "0"
}

@test "the box-HOME guard rejects a HOME cell whose last line says all host config is unaffected" {
    local _f="${BATS_TEST_TMPDIR}/host_config_home.svg"
    _write_fixture_flow "${_f}" "$(_home_expected_lines | sed '$d')"$'\n'"${OLD_HOME_LINE_5}" "x"
    sed -i 's/f_test/home/g' "${_f}"
    run _home_cell_ok "${_f}"
    assert_failure
}

# --- #179: no tmux between the terminal and the box's fish -------------------
#
# The terminal runs `distrobox enter dev` and lands in the box's fish; it
# starts no tmux (the old `-- tmux new -A -s main` attached to a HOST tmux
# server whenever one was running). The diagrams are the single source of
# truth for that chain, so they must not draw ghostty -> tmux -> fish.
# Scoped to the cells of the chain, like the #163 guard.

@test "#179 architecture diagram: the terminal chain is ghostty -> distrobox enter dev -> fish, no tmux cell" {
    local _f
    _f="$(_svg architecture)"
    run _cell_label_lines "${_f}" t_enter
    assert_success
    assert_output "distrobox enter dev"
    run _source_cell "${_f}" t_enter
    assert_output --partial "value=&quot;distrobox enter dev&quot;"
    # Both edges of the chain go through t_enter.
    run _source_cell "${_f}" e_t1
    assert_output --partial "source=&quot;t_ghostty&quot;"
    assert_output --partial "target=&quot;t_enter&quot;"
    run _source_cell "${_f}" e_t2
    assert_output --partial "source=&quot;t_enter&quot;"
    assert_output --partial "target=&quot;t_fish&quot;"
    # The old middle node is gone, rendered and in the source.
    run _cell_label_lines "${_f}" t_tmux
    assert_output ""
    run grep -c "t_tmux" "${_f}"
    assert_failure
    run _cell_label_lines "${_f}" t_note
    refute_output --regexp "由 tmux 帶起"
}

@test "#179 flow diagram: the enter node names distrobox enter dev -> fish, no tmux" {
    run _cell_label_lines "$(_svg flow)" f_enter
    assert_success
    assert_line --index 2 "→ distrobox enter dev → fish"
    refute_output --partial "tmux"
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
