import Foundation

extension TextLanguages {
    /// Data, configuration and build files.
    static let data: [TextLanguage] = [
        TextLanguage(
            "json", "JSON",
            code {
                $0.lineComments = cComments.line
                $0.blockComments = cComments.block
                $0.strings = [StringRule("\"")]
                $0.literals = words("true false null")
                $0.keysBeforeColon = true
                $0.functionCalls = false
            }, extensions: ["json", "jsonc", "json5", "geojson", "webmanifest", "har", "ipynb"],
            fileNames: [".babelrc", ".eslintrc", ".prettierrc", "package.lock"]),
        TextLanguage(
            "sql", "SQL",
            code {
                $0.lineComments = [Array("--".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [
                    StringRule("'", escape: false, doubled: true), StringRule("\"", escape: false),
                    StringRule("`", escape: false),
                ]
                $0.keywords = words(
                    """
                    select from where and or not insert into values update set delete create table view index drop \
                    alter add column primary key foreign references unique default check constraint join inner left \
                    right outer full cross on as group by order having limit offset union all distinct case when then \
                    else end in is like between exists asc desc begin commit rollback transaction with recursive \
                    returning if replace trigger procedure function returns declare cast database schema grant revoke \
                    truncate merge using over partition window
                    """)
                $0.types = words(
                    "int integer bigint smallint tinyint decimal numeric float real double varchar char text blob date time timestamp boolean serial uuid json jsonb"
                )
                $0.literals = words("null true false")
                $0.caseInsensitive = true
                $0.attributePrefixes = [Char.at, Char.colon]
            }, extensions: ["sql", "ddl", "dml", "psql", "mysql", "sqlite"]),
        TextLanguage(
            "graphql", "GraphQL",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\"\"\"", multiline: true), StringRule("\"")]
                $0.keywords = words(
                    "query mutation subscription fragment on type interface union enum input scalar schema extend implements directive repeatable"
                )
                $0.literals = words("true false null")
                $0.attributePrefixes = [Char.at]
                $0.variablePrefix = Char.dollar
                $0.capitalizedTypes = true
            }, extensions: ["graphql", "gql", "graphqls"]),
        TextLanguage(
            "protobuf", "Protocol Buffers",
            cLike(
                keywords:
                    "syntax edition import weak public package option message enum service rpc returns stream oneof map reserved extensions extend optional required repeated to max",
                types:
                    "double float int32 int64 uint32 uint64 sint32 sint64 fixed32 fixed64 sfixed32 sfixed64 bool string bytes"
            ) { $0.capitalizedTypes = true }, extensions: ["proto"]),
        TextLanguage(
            "thrift", "Thrift",
            cLike(
                keywords:
                    "namespace include typedef struct union exception enum const service extends throws oneway required optional void",
                types: "bool byte i8 i16 i32 i64 double string binary list set map"
            ) { $0.lineComments = [Array("//".utf16), Array("#".utf16)] }, extensions: ["thrift"]),
        TextLanguage(
            "hcl", "Terraform",
            code {
                $0.lineComments = [Array("#".utf16), Array("//".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [StringRule("\"")]
                $0.keywords = words(
                    "resource data variable output module provider locals terraform for in if each count depends_on lifecycle dynamic content"
                )
                $0.literals = words("true false null")
            }, extensions: ["tf", "tfvars", "hcl", "nomad"]),
        TextLanguage(
            "nix", "Nix",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [StringRule("''", escape: false, multiline: true), StringRule("\"")]
                $0.keywords = words("let in with rec inherit if then else assert import or")
                $0.literals = words("true false null")
                $0.identifierExtras = [Char.minus, Char.apostrophe]
            }, extensions: ["nix"]),
        TextLanguage(
            "cmake", "CMake",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\"", multiline: true)]
                $0.keywords = words(
                    "if elseif else endif foreach endforeach while endwhile function endfunction macro endmacro return set unset option project include add_executable add_library target_link_libraries target_include_directories find_package cmake_minimum_required install message"
                )
                $0.literals = words("ON OFF TRUE FALSE YES NO")
                $0.variablePrefix = Char.dollar
                $0.caseInsensitive = true
            }, extensions: ["cmake"], fileNames: ["cmakelists.txt"]),
        TextLanguage(
            "makefile", "Makefile",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    "ifeq ifneq ifdef ifndef else endif include -include sinclude define endef export unexport override vpath .PHONY"
                )
                $0.variablePrefix = Char.dollar
                $0.lineStartLabels = true
                $0.functionCalls = false
                $0.identifierExtras = [Char.minus, Char.dot, Char.slash]
            }, extensions: ["mk", "mak", "make"], fileNames: ["makefile", "gnumakefile", "bsdmakefile"]),
        TextLanguage(
            "dockerfile", "Dockerfile",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    "from as run cmd label maintainer expose env add copy entrypoint volume user workdir arg onbuild stopsignal healthcheck shell"
                )
                $0.caseInsensitive = true
                $0.variablePrefix = Char.dollar
                $0.functionCalls = false
            }, extensions: ["dockerfile", "containerfile"], fileNames: ["dockerfile", "containerfile"]),
        TextLanguage(
            "asm", "Assembly",
            code {
                $0.lineComments = [Array(";".utf16), Array("#".utf16), Array("//".utf16)]
                $0.blockComments = cComments.block
                $0.strings = [StringRule("\""), StringRule("'")]
                $0.keywords = words(
                    "mov movl movq add sub mul div inc dec push pop call ret jmp je jne jz jnz cmp test and or xor not shl shr lea nop int syscall ldr str bl b bx cbz cbnz adr adrp stp ldp"
                )
                $0.attributePrefixes = [Char.dot, Char.percent]
                $0.lineStartLabels = true
                $0.caseInsensitive = true
                $0.functionCalls = false
            }, extensions: ["s", "asm", "nasm"]),
        TextLanguage(
            "vim", "Vim Script",
            code {
                $0.lineComments = [Array("\"".utf16)]
                $0.strings = [StringRule("'", escape: false)]
                $0.keywords = words(
                    "let set if else elseif endif for endfor while endwhile function endfunction call return autocmd augroup map nmap vmap imap noremap nnoremap vnoremap inoremap command syntax highlight execute"
                )
            }, extensions: ["vim"], fileNames: [".vimrc", ".gvimrc", "_vimrc"]),
        TextLanguage(
            "log", "Log",
            code {
                $0.strings = [StringRule("\"")]
                $0.keywords = words("ERROR FATAL CRITICAL WARN WARNING error fatal warning Error Warning Fatal")
                $0.literals = words("INFO DEBUG TRACE NOTICE info debug trace notice true false null")
                $0.functionCalls = false
            }, extensions: ["log"]),
        TextLanguage("yaml", "YAML", .yaml, extensions: ["yaml", "yml"], fileNames: [".clang-format", ".clang-tidy"]),
        TextLanguage(
            "toml", "TOML",
            .ini(
                {
                    var rules = INIRules()
                    rules.semicolonComments = false
                    rules.typedValues = true
                    return rules
                }()), extensions: ["toml"], fileNames: ["cargo.lock", "pipfile", "poetry.lock"]),
        TextLanguage(
            "ini", "INI", .ini(INIRules()),
            extensions: ["ini", "cfg", "conf", "config", "inf", "reg", "desktop", "service", "editorconfig"],
            fileNames: [
                ".gitconfig", ".editorconfig", ".npmrc", ".gitmodules", ".flake8", ".pylintrc", "setup.cfg", "tox.ini",
            ]),
        TextLanguage(
            "properties", "Properties",
            .ini(
                {
                    var rules = INIRules()
                    rules.semicolonComments = false
                    rules.colonSeparates = true
                    return rules
                }()), extensions: ["properties"]),
        TextLanguage(
            "dotenv", "Environment File",
            .ini(
                {
                    var rules = INIRules()
                    rules.semicolonComments = false
                    rules.exportKeyword = true
                    return rules
                }()), extensions: ["env"], fileNames: [".env", ".envrc", ".flaskenv"]),
        TextLanguage(
            "ignore", "Ignore List",
            code {
                $0.lineComments = [Array("#".utf16)]
                $0.functionCalls = false
            },
            fileNames: [
                ".gitignore", ".dockerignore", ".npmignore", ".gitattributes", ".hgignore", ".eslintignore",
                ".prettierignore", "codeowners",
            ]),
        TextLanguage("diff", "Diff", .diff, extensions: ["diff", "patch", "rej"]),
        TextLanguage("csv", "CSV", .plain, extensions: ["csv", "tsv", "tab", "psv"]),
    ]
}
