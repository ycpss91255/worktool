# Build the table from just's public JSON interface, including every loaded mod.
def default_kind:
    if .first != "default" or .recipes.default == null then "missing"
    elif .recipes.default.dependencies != [] then "unknown"
    elif (.source | ltrimstr($root + "/")) as $source |
         .recipes.default.body as $body |
         (["@just --justfile '", [["call", "source_file"]], "' --list"]) as $self |
         (["@just --justfile " + $source + " --list"]) as $literal |
         ($body == [$self] or $body == [$literal] or
          $body == [$self, ["@echo 'NOTE: listing checks does not run verification.'"]]) then "list"
    elif .recipes.default.body == [["./script/test/test.sh"]] then "all"
    else "unknown" end;

def module_contract:
    .modules | to_entries | map(
        .key as $ns | .value as $m |
        ($m.source | ltrimstr($root + "/") | split("/") | .[:-1] | join("/") + "/") as $dir |
        {ns: $ns, dir: $dir, cwd: $m.settings.working_directory,
         default: ($m | default_kind), help: ($m.recipes.help != null),
         alias: ($m.aliases.h.target == "help")});

def table_row:
    "| `\(.ns)` | `\(.dir)` | " +
    (if .default == "all" then "跑全部 CI 步驟" elif .default == "list" then "列出動詞" else .default end) +
    " | " + (if .help then
        if .alias then "`help`（alias `h`）" else "`help`（無 alias `h`）" end
        else "無；各動詞用 `--help`" end) + " | `'\(.cwd)'` |";

def names: split("、") | sort;
def selected($modules; predicate): [$modules[] | select(predicate) | .ns] | sort;

def design_contract:
    $design | split("\n5. ") | map(select(startswith("**每個 module"))) | .[0] | split("\n\n")[0] | gsub("[[:space:]`*]"; "") |
    . as $rule |
    (capture("(?<aliases>[a-z、]+)另有help\\(aliash\\),(?<help>[a-z、]+)有help(?<extra>\\(aliash\\))?,而(?<bare>[a-z、]+)由裸指令列出動詞")) as $help |
    (capture("(?<list>[a-z、]+)的裸just<ns>也列出動詞;(?<all>[a-z、]+)例外,裸justtest會跑CI的全部步驟")) as $default |
    (capture("script/<ns>/與.agents/script/用'(?<cwd>[^']+)'")) as $normal |
    (capture(".agents/script/worktree/用'(?<cwd>[^']+)'")) as $worktree |
    {aliases: (($help.aliases | names) + (if $help.extra != null then ($help.help | names) else [] end) | sort),
     help: (($help.aliases | names) + ($help.help | names) | sort),
     bare: ($help.bare | names), list: ($default.list | names), all: ($default.all | names),
     normal_cwd: $normal.cwd, worktree_cwd: $worktree.cwd,
     defaults: ($rule | contains("每個module都有自己的default"))};

module_contract as $modules |
([$modules[] | table_row] | sort) as $actual |
([$structure | split("| 命名空間 |")[1] | split("\n\n")[0] | split("\n")[] |
    select(startswith("| `"))] | sort) as $documented |
if $actual != $documented then error("namespace rules: structure table differs from modules")
else
    (design_contract // error("namespace rules: cannot parse design rule 5")) as $policy |
    if $policy.defaults and
        $policy.aliases == selected($modules; .alias) and
        $policy.help == selected($modules; .help) and
        $policy.bare == selected($modules; .help | not) and
        $policy.list == selected($modules; .default == "list") and
        $policy.all == selected($modules; .default == "all") and
        all($modules[]; .cwd == (if .dir == ".agents/script/worktree/" then
            $policy.worktree_cwd else $policy.normal_cwd end))
    then "namespace rules: modules, structure table and design rule 5 agree"
    else error("namespace rules: modules differ from design rule 5") end
end
